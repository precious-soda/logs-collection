# Logs Collection

This is a log management system that collects logs via Fluentd, stores them in Elasticsearch, and automatically exports them to CSV files daily with index lifecycle management to prevent storage overflow. It also monitors and reports disk space usage and performs monthly compression for easy transfer.

## 🏗️ Architecture

This system has two components:

1. **Log Collection Server** - Runs Fluentd + Elasticsearch (Docker) + Export/Monitoring services (systemd)
2. **Application Servers** - Your services that send logs to the collection server

## 🔧 Prerequisites

### On Log Collection Server
- Docker & docker-compose
- Python 3.x with uv (or pip)
- zstd
- Python packages: `pytz pandas python-dotenv elasticsearch==8.17`

### On Application Servers
- Docker (for Docker deployments) OR
- Ruby + Fluentd (for bare metal deployments)

## 🚀 Setup

### Step 1: Setup Log Collection Server
```bash
git clone https://github.com/precious-soda/logs-collection
cd logs-collection

# Update .env files with your paths
vim .env

# Start Fluentd and Elasticsearch
docker compose up -d
```

### Step 2: Configure Index Lifecycle Management

1. Open Kibana on localhost:5601 and click on ☰
2. Search Management and select Dev Tools
3. On the right, clear the boilerplate in the shell
4. Copy and paste the ilm_policy
5. Select each policy and click ▶️
6. Verify acknowledgement is displayed

### Step 3: Setup Automated Export

#### Create and enable CSV export service
```bash
# Update paths in the service file
sudo cp elasticsearch_export/logs_export.service /etc/systemd/system/
sudo cp elasticsearch_export/logs_export.timer /etc/systemd/system/

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable logs_export.timer
sudo systemctl start logs_export.timer

# Verify
systemctl status logs_export.service
systemctl list-timers | grep logs_export

# Test (recommended before relying on timer)
sudo systemctl start logs_export.service
```

#### Create and enable disk monitoring service
```bash
# Update paths in the service file
sudo cp disk_management/disk_monitor.service /etc/systemd/system/
sudo cp disk_management/disk_monitor.timer /etc/systemd/system/

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable disk_monitor.timer
sudo systemctl start disk_monitor.timer

# Verify
systemctl status disk_monitor.service
systemctl list-timers | grep disk_monitor

# Test (recommended before relying on timer)
sudo systemctl start disk_monitor.service
```

#### Setup log rotation
```bash
sudo vim /etc/logrotate.d/disk_monitor
sudo logrotate -f /etc/logrotate.d/disk_monitor  # Test
```

### Step 4: Configure Application Servers to Send Logs

Now configure your application servers to forward logs to the collection server.

#### For Docker Deployments

Add to your docker-compose.yml:
```yaml
logging:
  driver: "fluentd"
  options:
    fluentd-address: 10.33.42.15:24224  # Your log collection server IP
    tag: your-service-name
```

#### For Bare Metal Deployments
```bash
# Install Fluentd
sudo apt update
sudo apt install -y ruby ruby-dev
sudo gem install fluentd

# Run your service with log forwarding
sudo your-command 2>&1 \
| tee >(
  while read -r line; do
    jq -nc --arg log "$line" \
      '{"log":$log,"container_id":"-","container_name":"-","source":"stdout"}'
  done \
  | fluent-cat -h 10.33.42.15 -p 24224 your-service-name
)
```

**Important:** Replace `10.33.42.15` with your actual log collection server IP address.

## 📊 Viewing Logs

Your logs will be available:

- **Real-time:** Fluentd container stdout
- **Historical:** Elasticsearch/Kibana with index pattern `oai-*`
- **Exported:** CSV files in your configured OUTPUT_DIR