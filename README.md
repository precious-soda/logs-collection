# Logs Collection
Fluentd setup for collecting and forwarding logs to Elasticsearch with real-time monitoring capabilities.

## 🔧 Prerequisites 
- Docker
- docker-compose

## 🚀 Setup 
```bash
git clone https://github.com/precious-soda/logs-collection
cd logs-collection
docker compose up -d
```

## 📝 How to Configure Your Services for Log Collection
After setting up the log collection infrastructure, you need to configure your Docker services to send logs to Fluentd.

```bash
logging:
  driver: "fluentd"
  options:
    fluentd-address: localhost:24224
    tag: tg
```

## 📊 Viewing Logs
Once configured, your logs will be available:
- Real-time: In Fluentd container stdout
- Stored: In Elasticsearch with index pattern

