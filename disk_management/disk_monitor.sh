#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env file not found at $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a


THRESHOLD=80
CHECK_PATHS=( "/mnt/c" )
ALERT_STATE_FILE="/tmp/disk_alert_last"
MONTHLY_BATCH_SIZE=30
FILE_AGE_SAFETY_HOURS=2
MIN_EMERGENCY_SIZE_MB=400

ZSTD_LEVEL=3

ARCHIVE_DIR="$OUTPUT_DIR/compressed_archives"
STATE_FILE="$OUTPUT_DIR/.compression_state"

mkdir -p "$ARCHIVE_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

send_discord_alert() {
  local title="$1"
  local message="$2"
  local color="$3"

  [ -z "$DISCORD" ] && return

  payload=$(cat <<EOF
{
  "embeds": [{
    "title": "$title",
    "description": "$message",
    "color": $color
  }]
}
EOF
)

  curl -s -H "Content-Type: application/json" \
       -X POST \
       -d "$payload" \
       "$DISCORD" >/dev/null
}

[ -f "$STATE_FILE" ] || echo "last_compressed_date=" > "$STATE_FILE"

get_uncompressed_files() {
  local start_date="$1"
  local cutoff=$(( $(date +%s) - FILE_AGE_SAFETY_HOURS*3600 ))

  while IFS= read -r -d '' file; do
    [ -f "${file}.lock" ] && continue

    mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    [ "$mtime" -ge "$cutoff" ] && continue

    if [ -n "$start_date" ]; then
      fdate=$(basename "$file" | grep -oP '\d{4}-\d{2}-\d{2}')
      [[ "$fdate" < "$start_date" ]] && continue
    fi

    echo "$file"
  done < <(find "$OUTPUT_DIR" -maxdepth 1 -name "logs_*.csv" -type f -print0 | sort -z)
}

compress_batch() {
  local trigger="$1"; shift
  local files=("$@")

  [ ${#files[@]} -eq 0 ] && return 1

  first_date=$(basename "${files[0]}" | grep -oP '\d{4}-\d{2}-\d{2}')
  last_date=$(basename "${files[-1]}" | grep -oP '\d{4}-\d{2}-\d{2}')

  archive="$ARCHIVE_DIR/logs_${first_date}_to_${last_date}.tar.zst"
  [ -f "$archive" ] && archive="${archive%.tar.zst}_$(date +%s).tar.zst"

  size_before=$(du -sb "${files[@]}" | awk '{s+=$1} END{print s}')

  tar -C "$OUTPUT_DIR" -cf - -T <(basename -a "${files[@]}") | \
    zstd -$ZSTD_LEVEL -T0 -o "$archive"

  if ! zstd -t "$archive" >/dev/null 2>&1; then
    rm -f "$archive"
    return 1
  fi

  size_after=$(du -sb "$archive" | awk '{print $1}')
  rm -f "${files[@]}"

  echo "last_compressed_date=$last_date" > "$STATE_FILE"

  export COMPRESS_FROM="$first_date"
  export COMPRESS_TO="$last_date"
  export SIZE_BEFORE="$size_before"
  export SIZE_AFTER="$size_after"

  return 0
}

check_monthly_batch() {
  source "$STATE_FILE"

  mapfile -t files < <(get_uncompressed_files "$last_compressed_date")
  [ ${#files[@]} -lt "$MONTHLY_BATCH_SIZE" ] && return 1

  if compress_batch "monthly" "${files[@]:0:$MONTHLY_BATCH_SIZE}"; then
    usage=$(df -h "$OUTPUT_DIR" | awk 'NR==2{print $5}')
    send_discord_alert \
      "✅ Success: Monthly Compression" \
      "From: $COMPRESS_FROM\nTo: $COMPRESS_TO\nSize: $((SIZE_BEFORE/1024/1024))MB → $((SIZE_AFTER/1024/1024))MB\nDisk Usage: $usage" \
      65280
    exit 0
  else
    usage=$(df -h "$OUTPUT_DIR" | awk 'NR==2{print $5}')
    send_discord_alert \
      "❌ Error: Monthly Compression Unsuccessful" \
      "Disk Usage: $usage" \
      16711680
    exit 1
  fi
}

emergency_compress() {
  source "$STATE_FILE"

  mapfile -t files < <(get_uncompressed_files "$last_compressed_date")
  count=${#files[@]}
  [ "$count" -le 1 ] && return 1

  total_bytes=$(du -sb "${files[@]}" | awk '{s+=$1} END{print s}')
  total_mb=$((total_bytes / 1024 / 1024))
  [ "$total_mb" -lt "$MIN_EMERGENCY_SIZE_MB" ] && return 1

  if compress_batch "emergency" "${files[@]}"; then
    send_discord_alert \
      "⚠️ Warning: Emergency Compression" \
      "From: $COMPRESS_FROM\nTo: $COMPRESS_TO\nSize: $((SIZE_BEFORE/1024/1024))MB → $((SIZE_AFTER/1024/1024))MB" \
      16753920
    return 0
  else
    send_discord_alert \
      "❌ Error: Emergency Compression Unsuccessful" \
      "Compression failed during critical disk usage" \
      16711680
    return 1
  fi
}

check_disk() {
  local path="$1"
  usage=$(df -h "$path" | awk 'NR==2{print $5}' | tr -d '%')

  [ -z "$usage" ] && return

  if [ "$usage" -ge "$THRESHOLD" ]; then
    send_discord_alert \
      "🚨 Critical: Disk Space Low" \
      "Path: $path\nDisk Usage: ${usage}%" \
      16711680

    emergency_compress
    date +%s > "$ALERT_STATE_FILE"
    exit 0
  else
    echo "$(date): Disk usage at ${usage}%" >> "$LOG_FILE"
  fi
}

check_monthly_batch

for path in "${CHECK_PATHS[@]}"; do
  [ -d "$path" ] && check_disk "$path"
done
