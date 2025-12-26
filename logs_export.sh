#!/bin/bash

# Configuration
ES_HOST="http://localhost:9200"
INDEX="oai-logs"
OUTPUT_DIR="/path/to/save/the/logs"  # Change this to your desired output directory

PREV_DATE=$(date -d "yesterday" +"%Y-%m-%d")
CSV_FILE="$OUTPUT_DIR/logs_${PREV_DATE}.csv"

mkdir -p "$OUTPUT_DIR"

QUERY=$(cat <<EOF
{
  "query": {
    "range": {
      "@timestamp": {
        "gte": "${PREV_DATE}T00:00:00.000Z",
        "lt": "${PREV_DATE}T23:59:59.999Z"
      }
    }
  },
  "sort": ["@timestamp"],
  "size": 1000
}
EOF
)

TMP_RESP=$(mktemp)

if ! curl -s -f "$ES_HOST" > /dev/null; then
  echo "$(date): ERROR - Elasticsearch is down or unreachable at $ES_HOST" >&2
  echo "ERROR: Elasticsearch unreachable on $(date)" > "$CSV_FILE"
  echo "Query attempted: previous day $PREV_DATE" >> "$CSV_FILE"
  rm -f "$TMP_RESP"
  exit 1
fi

if ! curl -s -X GET "$ES_HOST/$INDEX/_search?scroll=1m" \
     -H 'Content-Type: application/json' -d "$QUERY" > "$TMP_RESP"; then
  echo "$(date): ERROR - Search request failed (index missing or other issue)" >&2
  echo "ERROR: Search failed on $(date)" > "$CSV_FILE"
  echo "Index: $INDEX, Date: $PREV_DATE" >> "$CSV_FILE"
  rm -f "$TMP_RESP"
  exit 1
fi

total_hits=$(jq -r '.hits.total.value // 0' "$TMP_RESP" 2>/dev/null || echo 0)

if [ "$total_hits" -eq 0 ]; then
  echo "$(date): No logs found for ${PREV_DATE} (this is normal on quiet days)"
  {
    echo '@log_name,@timestamp,_id,_index,container_id,log,message,source'
    echo '"NO_LOGS","","","","","","","No logs for this day"'
  } > "$CSV_FILE"
  rm -f "$TMP_RESP"
  exit 0
fi

echo '@log_name,@timestamp,_id,_index,container_id,log,message,source' > "$CSV_FILE"

safe_field() {
  echo "$1" | jq -r --arg f "$2" '._source[$f] // ""' | sed 's/"/""/g'
}

process_hits() {
  while IFS= read -r hit; do
    log_name=$(safe_field "$hit" "@log_name")
    container_id=$(safe_field "$hit" "container_id")
    log_msg=$(safe_field "$hit" "log")
    message=$(safe_field "$hit" "message")
    source=$(safe_field "$hit" "source")
    _id=$(echo "$hit" | jq -r '._id // ""')
    _index=$(echo "$hit" | jq -r '._index // ""')

    raw_timestamp=$(echo "$hit" | jq -r '._source."@timestamp" // ""')
    if [ -n "$raw_timestamp" ] && [ "$raw_timestamp" != "null" ]; then
      timestamp=$(TZ=Asia/Kolkata date -d "${raw_timestamp%Z}" +"%b %d, %Y @ %H:%M:%S.%3N" 2>/dev/null || echo "$raw_timestamp")
      timestamp=${timestamp/ 0/ }
    else
      timestamp=""
    fi

    printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
      "$log_name" "$timestamp" "$_id" "$_index" "$container_id" "$log_msg" "$message" "$source" >> "$CSV_FILE"
  done
}

hits=$(jq -c '.hits.hits[]' "$TMP_RESP")
echo "$hits" | process_hits

scroll_id=$(jq -r '._scroll_id // empty' "$TMP_RESP")

while [ -n "$scroll_id" ] && jq -e '.hits.hits | length > 0' "$TMP_RESP" >/dev/null; do
  curl -s -X GET "$ES_HOST/_search/scroll" \
    -H 'Content-Type: application/json' \
    -d "{\"scroll\":\"1m\",\"scroll_id\":\"$scroll_id\"}" > "$TMP_RESP" || break

  hits=$(jq -c '.hits.hits[]' "$TMP_RESP")
  [ -n "$hits" ] && echo "$hits" | process_hits

  scroll_id=$(jq -r '._scroll_id // empty' "$TMP_RESP")
done

[ -n "$scroll_id" ] && curl -s -X DELETE "$ES_HOST/_search/scroll" \
  -H 'Content-Type: application/json' -d "{\"scroll_id\":\"$scroll_id\"}" > /dev/null

rm -f "$TMP_RESP"

echo "$(date): Export completed: $CSV_FILE (Total: $total_hits logs from ${PREV_DATE})"