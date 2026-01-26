from datetime import datetime, timedelta
import pytz
import pandas as pd
from elasticsearch import Elasticsearch
from elasticsearch.exceptions import ConnectionError, TransportError
import requests
import os
from dotenv import load_dotenv

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(BASE_DIR, "..", ".env")
load_dotenv(dotenv_path=ENV_PATH)
OUTPUT_DIR = os.getenv("OUTPUT_DIR")
DISCORD_WEBHOOK = os.getenv("DISCORD")

ES_HOST = "http://localhost:9200"
INDEX = "oai-*"
BATCH_SIZE = 1000
LOCAL_TZ = pytz.timezone("Asia/Kolkata")
QUEUE_FILE = os.path.join(BASE_DIR, "queue.txt")

def format_file_size(bytes_size: int) -> str:
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if bytes_size < 1024:
            return f"{bytes_size:.2f} {unit}"
        bytes_size /= 1024
    return f"{bytes_size:.2f} PB"

def send_discord_alert(message: str, color: int = 3447003):
    if not DISCORD_WEBHOOK:
        print("DISCORD webhook not set. Cannot send alert.")
        return

    payload = {
        "embeds": [{
            "title": "Elasticsearch Export",
            "description": message,
            "color": color,
        }]
    }

    try:
        response = requests.post(DISCORD_WEBHOOK, json=payload, timeout=10)
        response.raise_for_status()
    except Exception as e:
        print(f"Failed to send Discord alert: {e}")

def add_date_to_queue(date_str: str):
    existing_dates = read_queue()
    if date_str not in existing_dates:
        with open(QUEUE_FILE, "a") as f:
            f.write(f"{date_str}\n")
        print(f"Added {date_str} to queue")

def read_queue() -> list:
    if not os.path.exists(QUEUE_FILE):
        return []
    with open(QUEUE_FILE, "r") as f:
        return [line.strip() for line in f if line.strip()]

def remove_date_from_queue(date_str: str):
    dates = read_queue()
    dates = [d for d in dates if d != date_str]
    with open(QUEUE_FILE, "w") as f:
        for d in dates:
            f.write(f"{d}\n")
    print(f"Removed {date_str} from queue")

def count_queue() -> int:
    return len(read_queue())

def export_logs_for_date(es: Elasticsearch, date_str: str) -> tuple:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    output_file = os.path.join(OUTPUT_DIR, f"logs_{date_str}.csv")

    date_local = datetime.strptime(date_str, "%Y-%m-%d")
    date_local = LOCAL_TZ.localize(date_local)

    start_local = date_local.replace(hour=0, minute=0, second=0, microsecond=0)
    end_local = date_local.replace(hour=23, minute=59, second=59, microsecond=999999)

    start_utc = start_local.astimezone(pytz.utc).isoformat()
    end_utc = end_local.astimezone(pytz.utc).isoformat()

    try:
        pit_response = es.open_point_in_time(index=INDEX, keep_alive="2m")
        pit_id = pit_response["id"]
    except Exception as e:
        print(f"Failed to open PIT for {date_str}: {e}")
        return 0, 0, False

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

    try:
        while True:
            body = {
                "size": BATCH_SIZE,
                "sort": [{"@timestamp": "asc"}],
                "pit": {"id": pit_id, "keep_alive": "2m"},
                "_source": True,
                "query": {
                    "must": [
                        {
                            "range": {
                                "@timestamp": {
                                    "gte": start_utc,
                                    "lte": end_utc
                                }
                            }
                        }
                    ],
                    "must_not": [
                        {
                            "term": {
                                "log.keyword": ""
                            }
                        }
                    ],
                    "filter": [
                        {
                            "exists": {
                                "field": "log"
                            }
                        }
                    ]
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
                ts = source.get("@timestamp")
                if ts:
                    try:
                        # Parse the full timestamp including milliseconds
                        if '.' in ts:
                            dt_utc = datetime.strptime(ts[:23], "%Y-%m-%dT%H:%M:%S.%f")
                        else:
                            dt_utc = datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")
                        
                        dt_utc = pytz.utc.localize(dt_utc)
                        dt_local = dt_utc.astimezone(LOCAL_TZ)
                        
                        # Format with actual milliseconds
                        source["@timestamp"] = dt_local.strftime("%b %-d, %Y @ %H:%M:%S.%f")[:-3]
                    except Exception:
                        pass

                source["_id"] = doc.get("_id", "")
                source["_index"] = doc.get("_index", "")
                filtered_source = {field: source.get(field, "") for field in FIELDS}
                all_logs.append(filtered_source)

            search_after = hits[-1]["sort"]

        es.close_point_in_time(body={"id": pit_id})

    except Exception as e:
        print(f"Error fetching logs for {date_str}: {e}")
        try:
            es.close_point_in_time(body={"id": pit_id})
        except:
            pass
        return 0, 0, False

    if not all_logs:
        return 0, 0, True

    df = pd.DataFrame(all_logs)
    df = df[FIELDS]

    # Rename columns for CSV output
    df = df.rename(columns={
        "@log_name": "log_name",
        "@timestamp": "timestamp",
        "_id": "id",
        "_index": "index"
    })

    df.to_csv(output_file, index=False)

    return len(df), os.path.getsize(output_file), True

def main():
    now_local = datetime.now(LOCAL_TZ)
    yesterday_local = now_local - timedelta(days=1)
    prev_date = yesterday_local.strftime("%Y-%m-%d")
    add_date_to_queue(prev_date)

    try:
        es = Elasticsearch(ES_HOST)
        if not es.ping():
            raise ConnectionError("Elasticsearch not reachable")
    except (ConnectionError, TransportError, Exception):
        send_discord_alert(
            f"CRITICAL: ES Down\nCount dates in queue: {count_queue()}",
            color=16711680
        )
        exit(1)

    present = {"dates": [], "total_logs": 0, "total_size": 0}
    absent = {"dates": []}

    while count_queue() > 0:
        date_str = read_queue()[0]
        print(f"Processing {date_str}...")

        total_logs, file_size, success = export_logs_for_date(es, date_str)

        if not success:
            print(f"Failed to process {date_str}. Keeping in queue.")
            break

        if total_logs > 0:
            present["dates"].append(date_str)
            present["total_logs"] += total_logs
            present["total_size"] += file_size
        else:
            absent["dates"].append(date_str)

        remove_date_from_queue(date_str)

    if count_queue() == 0:
        if present["dates"]:
            send_discord_alert(
                "Success: Logs Export Compeleted\n"
                f"Dates:\n" + "\n".join(present["dates"]) + "\n\n"
                f"Logs: {present['total_logs']}\n"
                f"Size: {format_file_size(present['total_size'])}",
                color=65280
            )

        if absent["dates"]:
            send_discord_alert(
                "Info: No logs\n"
                f"Dates:\n" + "\n".join(absent["dates"]),
                color=3447003
            )

    print("Export process completed.")

if __name__ == "__main__":
    main()
