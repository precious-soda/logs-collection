#!/bin/bash

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "ERROR: .env file not found at $ENV_FILE" >&2
    exit 1
fi

# Configuration
THRESHOLD=60
CHECK_PATHS=(
  "/mnt/c"
)
ALERT_COOLDOWN=3600
ALERT_STATE_FILE="/tmp/disk_alert_last"
ARCHIVE_DIR="$OUTPUT_DIR/compressed_archives"
MONTHLY_BATCH_SIZE=30
MIN_EMERGENCY_SIZE_MB=100
ZSTD_LEVEL=3
STATE_FILE="$OUTPUT_DIR/.compression_state"
FILE_AGE_SAFETY_HOURS=2

LOG_DIR=$(dirname "$LOG_FILE")
mkdir -p "$LOG_DIR"
mkdir -p "$OUTPUT_DIR"

# Discord alert function
send_discord_alert() {
  local message=$1
  local color=$2
  
  if [ -z "$DISCORD" ]; then
    echo "$(date): Discord webhook not configured" >> "$LOG_FILE"
    return 1
  fi
  
  local payload=$(cat <<EOF
{
  "embeds": [{
    "title": "Disk Alert",
    "description": "$message",
    "color": $color,
  }]
}
EOF
)
  
  curl -s -H "Content-Type: application/json" \
       -X POST \
       -d "$payload" \
       "$DISCORD" 2>/dev/null
  
  if [ $? -eq 0 ]; then
    echo "$(date): Discord alert sent successfully" >> "$LOG_FILE"
  else
    echo "$(date): Failed to send Discord alert" >> "$LOG_FILE"
  fi
}

if [ ! -f "$STATE_FILE" ]; then
  echo "last_compressed_date=" > "$STATE_FILE"
  echo "$(date): Initialized compression state file" >> "$LOG_FILE"
fi

get_uncompressed_files() {
  local start_date=$1
  local cutoff_time=$(($(date +%s) - (FILE_AGE_SAFETY_HOURS * 3600)))
  
  local -a result_files=()
  
  # Find all CSV files
  while IFS= read -r -d '' file; do
    if [ -f "${file}.lock" ]; then
      echo "$(date): Skipping locked file: $(basename "$file")" >> "$LOG_FILE"
      continue
    fi
    
    file_mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    if [ "$file_mtime" -ge "$cutoff_time" ]; then
      echo "$(date): Skipping recent file: $(basename "$file") (modified < ${FILE_AGE_SAFETY_HOURS}h ago)" >> "$LOG_FILE"
      continue
    fi
    
    if [ -n "$start_date" ]; then
      file_date=$(basename "$file" | grep -oP '\d{4}-\d{2}-\d{2}')
      if [[ "$file_date" < "$start_date" ]]; then
        continue
      fi
    fi
    
    result_files+=("$file")
  done < <(find "$OUTPUT_DIR" -maxdepth 1 -name "logs_*.csv" -type f -print0 | sort -z)
  
  ((${#result_files[@]})) && printf '%s\n' "${result_files[@]}"
}

compress_batch() {
  local trigger_type=$1
  shift
  local files=("$@")
  
  if [ ${#files[@]} -eq 0 ]; then
    return 1
  fi
  
  for file in "${files[@]}"; do
    if [ -f "${file}.lock" ]; then
      echo "$(date): ABORT: Found lock file during compression: $(basename ${file}.lock)" >> "$LOG_FILE"
      return 1
    fi
  done
  
  local first_date=$(basename "${files[0]}" | grep -oP '\d{4}-\d{2}-\d{2}')
  local last_date=$(basename "${files[-1]}" | grep -oP '\d{4}-\d{2}-\d{2}')
  local file_count=${#files[@]}
  
  mkdir -p "$ARCHIVE_DIR"
  
  local archive_name="$ARCHIVE_DIR/logs_${first_date}_to_${last_date}.tar.zst"
  
  if [ -f "$archive_name" ]; then
    local timestamp=$(date +%Y%m%d_%H%M%S)
    archive_name="$ARCHIVE_DIR/logs_${first_date}_to_${last_date}_${timestamp}.tar.zst"
    echo "$(date): Warning: Archive exists, adding timestamp" >> "$LOG_FILE"
  fi
  
  echo "$(date): [$trigger_type] Compressing $file_count files ($first_date to $last_date)..." >> "$LOG_FILE"
  
  local size_before=$(du -sb "${files[@]}" 2>/dev/null | awk '{sum+=$1} END {print sum}')
  
  tar -C "$OUTPUT_DIR" -cf - -T <(basename -a "${files[@]}") 2>/dev/null | \
    zstd -$ZSTD_LEVEL -T0 -o "$archive_name"
  
  if [ $? -eq 0 ]; then
    if zstd -t "$archive_name" 2>/dev/null && \
       tar --zstd -tf "$archive_name" >/dev/null 2>&1; then
      
      local size_after=$(du -sb "$archive_name" 2>/dev/null | awk '{print $1}')
      local saved_bytes=$((size_before - size_after))
      local saved_percent=$(awk "BEGIN {printf \"%.1f\", (($saved_bytes / $size_before) * 100)}")
      local ratio=$(awk "BEGIN {printf \"%.2f\", ($size_before / $size_after)}")
      
      rm -f "${files[@]}"
      
      echo "last_compressed_date=$last_date" > "$STATE_FILE"
      
      local msg="✓ [$trigger_type] Compressed: logs_${first_date}_to_${last_date}.tar.zst"
      
      if [ $size_before -ge 1048576 ]; then
        size_before_display="$((size_before / 1024 / 1024))MB"
      else
        size_before_display=$(awk "BEGIN {printf \"%.1f\", $size_before / 1024}")KB
      fi
      
      if [ $size_after -ge 1048576 ]; then
        size_after_display="$((size_after / 1024 / 1024))MB"
      else
        size_after_display=$(awk "BEGIN {printf \"%.1f\", $size_after / 1024}")KB
      fi
      
      if [ $saved_bytes -ge 1048576 ]; then
        saved_display="$((saved_bytes / 1024 / 1024))MB"
      else
        saved_display=$(awk "BEGIN {printf \"%.1f\", $saved_bytes / 1024}")KB
      fi
      
      echo "$(date): $msg" >> "$LOG_FILE"
      echo "$(date):    Files: $file_count | Size: $size_before_display → $size_after_display | Saved: $saved_display (${saved_percent}%) | Ratio: ${ratio}x" >> "$LOG_FILE"      
      return 0
    else
      echo "$(date): ✗ Archive verification FAILED - keeping original files" >> "$LOG_FILE"
      rm -f "$archive_name"
      return 1
    fi
  else
    echo "$(date): ✗ Compression FAILED" >> "$LOG_FILE"
    return 1
  fi
}

check_monthly_batch() {
  last_compressed_date=""
  source "$STATE_FILE" 2>/dev/null

  mapfile -t files < <(get_uncompressed_files "$last_compressed_date")
  local count=${#files[@]}

  if [ "$count" -ge "$MONTHLY_BATCH_SIZE" ]; then
    echo "$(date): Monthly batch threshold reached ($count files)" >> "$LOG_FILE"

    local batch=("${files[@]:0:$MONTHLY_BATCH_SIZE}")
    compress_batch "monthly" "${batch[@]}"
    return $?
  fi

  return 1
}

emergency_compress() {
  local triggering_path=$1
  local usage=$2
  
  echo "$(date): 🚨 EMERGENCY COMPRESSION triggered by ${triggering_path} at ${usage}% disk usage" >> "$LOG_FILE"
  
  source "$STATE_FILE"
  
  mapfile -t files < <(get_uncompressed_files "$last_compressed_date")
  local count=${#files[@]}
  
  # Check if we have more than 1 file
  if [ $count -le 1 ]; then
    echo "$(date): Emergency Compression Skipped $count CSV file(s) available (need >1)" >> "$LOG_FILE"
    send_discord_alert "🚨 CRITICAL: Emergency Compression Skipped\\n$count CSV file(s) available (need >1)" 16711680
    return 1
  fi

  # Calculate total size of all CSV files
  local total_size_bytes=$(du -sb "${files[@]}" 2>/dev/null | awk '{sum+=$1} END {print sum}')
  local total_size_mb=$((total_size_bytes / 1024 / 1024))

  # Check if total size meets minimum threshold
  if [ $total_size_mb -lt $MIN_EMERGENCY_SIZE_MB ]; then
    echo "$(date): Emergency compression skipped - total size ${total_size_mb}MB is below minimum ${MIN_EMERGENCY_SIZE_MB}MB" >> "$LOG_FILE"
    send_discord_alert "🚨 CRITICAL: Emergency Compression Skipped\\n$count CSV file(s) (${total_size_mb}MB < ${MIN_EMERGENCY_SIZE_MB}MB Threshold)" 16711680
    return 1
  fi  
  
  echo "$(date): Emergency compressing ALL $count uncompressed files" >> "$LOG_FILE"
  
  compress_batch "emergency" "${files[@]}"
  
  return $?
}

check_disk() {
  local path=$1
  
  if [ ! -d "$path" ]; then
    echo "$(date): Skipping non-existent path: $path" >> "$LOG_FILE"
    return
  fi
  
  local usage=$(df -h "$path" 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')
  
  if [ -z "$usage" ]; then
    echo "$(date): Could not get disk usage for: $path" >> "$LOG_FILE"
    return
  fi
  
  local available=$(df -h "$path" 2>/dev/null | awk 'NR==2 {print $4}')
  
  if [ "$usage" -ge "$THRESHOLD" ]; then
    if [ -f "$ALERT_STATE_FILE" ]; then
      last_alert=$(cat "$ALERT_STATE_FILE")
      current_time=$(date +%s)
      time_diff=$((current_time - last_alert))
      
      if [ "$time_diff" -lt "$ALERT_COOLDOWN" ]; then
        return
      fi
    fi
    
    local message="⚠️ DISK ALERT: ${path} is ${usage}% full (${available} remaining)"
    echo "$(date): $message" >> "$LOG_FILE"

    send_discord_alert "🚨 CRITICAL: Disk Space Alert\\n${path} is ${usage}% full (${available} free)" 16711680
    
    if [ -n "$DISPLAY" ] && command -v notify-send &> /dev/null; then
      SUDO_USER=${SUDO_USER:-$(who | awk 'NR==1 {print $1}')}
      sudo -u $SUDO_USER DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u $SUDO_USER)/bus \
        notify-send -u critical "Disk Space Warning" "$message" 2>/dev/null
    fi
  
    emergency_compress "$path" "$usage"
    compress_status=$?

    if [ "$compress_status" -eq 0 ]; then
      send_discord_alert "✅ SUCCESS: Emergency Compression completed\\nCompressed files on ${path}\\nChecking disk status..." 65280
      sleep 2
      new_usage=$(df -h "$path" 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')
      
      if [ -z "$new_usage" ]; then
        echo "$(date): ✗ Failed to get disk usage after compression" >> "$LOG_FILE"
        send_discord_alert "❌ ERROR: Cannot verify disk status after compression on ${path}" 16711680
      else
        freed=$((usage - new_usage))  
        if [ "$freed" -gt 0 ]; then
          echo "$(date): Freed ${freed}% space on ${path} (${usage}% → ${new_usage}%)" >> "$LOG_FILE"
          send_discord_alert "Freed ${freed}% space on ${path} (${usage}% → ${new_usage}%)" 65280
        else
          echo "$(date): ⚠️ No space freed on ${path} after compression (${usage}% → ${new_usage}%)" >> "$LOG_FILE"
        fi
        
        if [ "$new_usage" -ge "$THRESHOLD" ]; then
          echo "$(date): ⚠️ ${path} still at ${new_usage}% after compression" >> "$LOG_FILE"
          send_discord_alert "⚠️ WARNING: Disk Still Critical\\n${path} remains at ${new_usage}%" 16753920
        fi
      fi
    fi

    date +%s > "$ALERT_STATE_FILE"
  fi
}

check_elasticsearch() {
  if curl -s -f "http://localhost:9200" > /dev/null 2>&1; then
    es_usage=$(curl -s "http://localhost:9200/_cat/allocation?v&h=disk.percent" 2>/dev/null | tail -n1 | tr -d ' ')
    
    if [ -n "$es_usage" ] && [ "${es_usage%.*}" -ge "$THRESHOLD" ]; then
      message="⚠️ ELASTICSEARCH ALERT: Disk usage at ${es_usage}%"
      echo "$(date): $message" >> "$LOG_FILE"
      send_discord_alert "⚠️ Elasticsearch Alert: Disk usage at ${es_usage}%" 15158332
    fi
  fi
}

# Main execution
check_monthly_batch

if [ $? -eq 0 ]; then
  # Monthly compression succeeded - no need to check disk
  echo "$(date): Monthly compression completed, skipping disk checks" >> "$LOG_FILE"
else
  # No monthly compression or it failed - check disk status
  for path in "${CHECK_PATHS[@]}"; do
    if [ -d "$path" ]; then
      check_disk "$path"
    fi
  done
fi

check_elasticsearch