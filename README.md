# Logs Collection System

This system collects logs using Fluentd, stores them in Elasticsearch, automatically exports them to CSV files daily and manages index lifecycle to prevent storage overflow.

## 🔧 Prerequisites

- Docker
- docker-compose

## 🚀 Setup

```bash
git clone https://github.com/precious-soda/logs-collection
cd logs-collection

# uncomment Elasticsearch and Kibana in docker-compose.yaml if you want to run them on the same host and use host elasticsearch in fluent.conf
docker compose up -d
```

## 📝 How to Configure Your Services for Log Collection

You need to configure your Docker services to send logs to Fluentd using the Fluentd logging driver also use unique tags for each service.

```bash
logging:
  driver: "fluentd"
  options:
    fluentd-address: localhost:24224
    tag: du
```

## 📊 Viewing Logs

Once configured, your logs will be available:

- Real-time: In Fluentd container stdout
- Stored: In Elasticsearch with index pattern

## 🗂️ Index Lifecycle Management (ILM)

This setup uses Elasticsearch ILM to automatically manage log retention and optimize storage:

- Rolls over indices when they reach a certain size or age.
- Deletes old indices after a retention period.
- Optimizes storage by moving older data to different tiers.

### Setting up ILM in Kibana

1. Open Kibana and click on ☰.
2. Search Management and select Dev Tools.
3. On the right clear the Boilerplate in the shell.
4. Copy and paste the ilm_policy.
5. Then select each of them and click on ▶️ button.
6. An acknowledgement will be displayed on the right.

## ➰ Elasticsearch Logs Export to CSV using systemd timer

This guide explains how to set up automatic daily export of the previous day's Elasticsearch logs to CSV using systemd timer on a Linux system.

We use two systemd units:

- `logs_export.service` — a **oneshot** service that runs the export script.
- `logs_export.timer` — a timer that triggers the service every day at 1:00 AM (with randomization).

### 1. Create the service file

```bash
# use the file logs_export.service also update the path and replace the user_name with the actual username
sudo vim /etc/systemd/system/logs_export.service
```

### 2. Create the timer file

```bash
# use the file logs_export.timer
sudo vim /etc/systemd/system/logs_export.timer
```

### 3. Reload systemd and enable timer

```bash
# update the logs_export.sh OUTPUT_DIR path
sudo systemctl daemon-reload
sudo systemctl enable logs_export.timer
sudo systemctl start logs_export.timer
```

### 4. Check Status

```bash
# check if timer is active
systemctl list-timers | grep logs_export

# check next run time
systemctl list-timers --all

# view logs of the last run
journalctl -u logs_export.service -e
```

### 5. Manually test the service (recommended before relying on timer)

```bash
sudo systemctl start logs_export.service
```
