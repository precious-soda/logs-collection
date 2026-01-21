# Logs Collection System

This system collects logs using Fluentd, stores them in Elasticsearch, automatically exports them to CSV files daily and manages index lifecycle to prevent storage overflow.

## 🔧 Prerequisites

- Docker
- docker-compose
- zstd
- uv

## ⚠️ Important Configuration Note

Before running the system make sure to update all paths in the `.env` files to match your environment and directory structure.

## 🚀 Setup

```bash
git clone https://github.com/precious-soda/logs-collection
cd logs-collection
docker compose up -d
```

## 📝 How to Configure Log Collection

Choose the appropriate method based on your deployment type:

### 🐳 Docker Deployments

Configure your Docker services to send logs to Fluentd using the Fluentd logging driver. Make sure to use unique tags for each Docker service.

```bash
logging:
  driver: "fluentd"
  options:
    fluentd-address: 10.33.42.15:24224
    tag: du
```

### 🖥️ Bare Metal Deployments

When running services directly on bare metal, use the following command pattern to collect and forward logs.

```bash
sudo apt update
sudo apt install -y ruby ruby-dev
sudo gem install fluentd

sudo filename 2>&1 \
| tee >(
  while read -r line; do
    jq -nc --arg log "$line" \
      '{"log":$log,"container_id":"-","container_name":"-","source":"stdout"}'
  done \
  | fluent-cat -h 10.33.42.15 -p 24224 du
)
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

## ➰ Automated Log Export and Compressed Archiving

This guide walks you through setting up a pipeline to export Elasticsearch logs to CSV files daily, monitor disk usage and compress older CSV files using tar + zstd.

### Set Up CSV Export

#### 1. Create the service

```bash
# Update the logs_export.service file
sudo vim /etc/systemd/system/logs_export.service
```

#### 2. Create the timer

```bash
sudo vim /etc/systemd/system/logs_export.timer
```

#### 3. Enable and start services

```bash
# Reload systemd to recognize new services
sudo systemctl daemon-reload

# Enable and start logs exporter
sudo systemctl enable logs_export.timer
sudo systemctl start logs_export.timer
```

#### 4. Check Status

```bash
# Check logs_export service status
systemctl status logs_export.service

# check if timer is active
systemctl list-timers | grep logs_export

# check next run time
systemctl list-timers --all

# view logs of the last run
journalctl -u logs_export.service -e
```

#### 5. Manually test the service (recommended before relying on timer)

```bash
sudo systemctl start logs_export.service
```

### Set Up Disk Monitoring and Compressed Archiving

#### 1. Create the service

```bash
# Update disk_management/disk_monitor.service file
sudo vim /etc/systemd/system/disk_monitor.service
```

#### 2. Create the timer

```bash
sudo vim /etc/systemd/system/disk_monitor.timer
```

#### 2. Enable and start services

```bash
# Reload systemd to recognize new services
sudo systemctl daemon-reload

# Enable and start disk monitor
sudo systemctl enable disk_monitor.timer
sudo systemctl start disk_monitor.timer
```

#### 4. Check status

```bash
# Check disk_monitor service status
systemctl status disk-monitor.service

# check if timer is active
systemctl list-timers | grep disk_monitor

# check next run time
systemctl list-timers --all

# view logs of the last run
journalctl -u disk-monitor.service -e

# Detailed disk monitor log file
sudo tail -f /path/to/disk_monitor.log
```

#### 5. Manually test the service (recommended before relying on timer)

```bash
sudo systemctl start disk_monitor.service
```

### Set Up Log Rotation

#### 1. Create logrotate configuration

```bash
# Use the logrotate file
sudo vim /etc/logrotate.d/disk_monitor
```

### 2. Test

```bash
sudo logrotate -f /etc/logrotate.d/disk_monitor
```
