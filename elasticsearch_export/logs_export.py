from datetime import datetime, timedelta
import pytz
import pandas as pd
from elasticsearch import Elasticsearch
from elasticsearch.exceptions import ConnectionError, TransportError
import requests
import os
from dotenv import load_dotenv

# --- LOAD ENVIRONMENT VARIABLES ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(BASE_DIR, "..", ".env")
load_dotenv(dotenv_path=ENV_PATH)
OUTPUT_DIR = os.getenv("OUTPUT_DIR")
DISCORD_WEBHOOK = os.getenv("DISCORD")

# --- CONFIGURATION ---
ES_HOST = "http://localhost:9200"
INDEX = "oai-*"
BATCH_SIZE = 1000
LOCAL_TZ = pytz.timezone("Asia/Kolkata")

# --- FILE SIZE FORMATTER ---
def format_file_size(bytes_size: int) -> str:
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if bytes_size < 1024:
            return f"{bytes_size:.2f} {unit}"
        bytes_size /= 1024
    return f"{bytes_size:.2f} PB"

# --- CALCULATE PREVIOUS DAY IN LOCAL TIMEZONE ---
now_local = datetime.now(LOCAL_TZ)
yesterday_local = now_local - timedelta(days=1)
PREV_DATE = yesterday_local.strftime("%Y-%m-%d")

os.makedirs(OUTPUT_DIR, exist_ok=True)
OUTPUT_FILE = os.path.join(OUTPUT_DIR, f"logs_{PREV_DATE}.csv")

start_local = yesterday_local.replace(hour=0, minute=0, second=0, microsecond=0)
end_local = yesterday_local.replace(hour=23, minute=59, second=59, microsecond=999999)

# Convert to UTC for Elasticsearch
start_utc = start_local.astimezone(pytz.utc).isoformat()
end_utc = end_local.astimezone(pytz.utc).isoformat()

# --- DISCORD ALERT FUNCTION ---
def send_discord_alert(message: str, color: int = 3447003):
    if not DISCORD_WEBHOOK:
        print("DISCORD webhook not set. Cannot send alert.")
        return

    payload = {
        "embeds": [{
            "title": "Logs Export",
            "description": message,
            "color": color,
        }]
    }

    try:
        response = requests.post(DISCORD_WEBHOOK, json=payload, timeout=10)
        response.raise_for_status()
    except Exception as e:
        print(f"Failed to send Discord alert: {e}")

# --- CONNECT TO ELASTICSEARCH ---
try:
    es = Elasticsearch(ES_HOST)
    if not es.ping():
        raise ConnectionError("Elasticsearch not reachable")
except (ConnectionError, TransportError, Exception):
    send_discord_alert(
        f"🚨 **CRITICAL: Elasticsearch Unreachable**\n"
        f"Host: {ES_HOST}\n"
        f"Date attempted: {PREV_DATE}\n"
        f"Export **FAILED**",
        color=16711680
    )
    exit(1)

# --- OPEN PIT ---
pit_response = es.open_point_in_time(index=INDEX, keep_alive="2m")
pit_id = pit_response["id"]

all_logs = []
search_after = None

FIELDS = [
    "@log_name",
    "@timestamp",
    "_id",
    "_index",
    "container_id",
    "container_name",
    "log",
    "source"
]

# --- FETCH LOGS ---
while True:
    body = {
        "size": BATCH_SIZE,
        "sort": [{"@timestamp": "asc"}],
        "pit": {"id": pit_id, "keep_alive": "2m"},
        "_source": True,
        "query": {
            "range": {
                "@timestamp": {
                    "gte": start_utc,
                    "lte": end_utc
                }
            }
        }
    }

    if search_after:
        body["search_after"] = search_after

    resp = es.search(body=body)
    hits = resp["hits"]["hits"]

    if not hits:
        break

    for doc in hits:
        source = doc.get("_source", {})

        # --- TIMEZONE-AWARE TIMESTAMP ---
        ts = source.get("@timestamp")
        if ts:
            try:
                dt_utc = datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")
                dt_utc = pytz.utc.localize(dt_utc)
                dt_local = dt_utc.astimezone(LOCAL_TZ)
                source["@timestamp"] = dt_local.strftime("%b %-d, %Y @ %H:%M:%S.000")
            except Exception:
                pass

        # --- ADD ES METADATA ---
        source["_id"] = doc.get("_id", "")
        source["_index"] = doc.get("_index", "")

        filtered_source = {field: source.get(field, "") for field in FIELDS}
        all_logs.append(filtered_source)

    search_after = hits[-1]["sort"]

# --- CLOSE PIT ---
es.close_point_in_time(body={"id": pit_id})

# --- EXPORT CSV ---
if not all_logs:
    send_discord_alert(
        f"ℹ️ **INFO: No Logs Found**\nDate: {PREV_DATE}",
        color=3447003
    )
else:
    df = pd.DataFrame(all_logs)
    df = df[FIELDS]
    df.to_csv(OUTPUT_FILE, index=False)

    file_size = format_file_size(os.path.getsize(OUTPUT_FILE))
    total_hits = len(df)

    send_discord_alert(
        f"✅ **SUCCESS: Export Completed**\n"
        f"Date: {PREV_DATE}\n"
        f"Total logs: {total_hits}\n"
        f"File: `{os.path.basename(OUTPUT_FILE)}`\n"
        f"Size: **{file_size}**",
        color=65280
    )

print(f"Export completed for {PREV_DATE}. Total logs: {len(all_logs)}")