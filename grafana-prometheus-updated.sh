#!/bin/bash
set -e

echo "=============================="
echo " Installing Prometheus + Grafana + Alertmanager + Node Exporter"
echo " Versions: Prometheus 3.11.0 | Alertmanager 0.32.0 | Node Exporter 1.11.1 | Grafana 13.x"
echo "=============================="

# ============ 0. Pre-flight: Disk Space Check ============
# Use /root as working directory — avoids /tmp space limits (tmpfs is often small on EC2)
WORKDIR="/root/install-tmp"
mkdir -p "$WORKDIR"

AVAIL_KB=$(df -k "$WORKDIR" | awk 'NR==2 {print $4}')
REQUIRED_KB=700000  # ~700 MB needed for all downloads + extractions
if [ "$AVAIL_KB" -lt "$REQUIRED_KB" ]; then
  echo "❌ Not enough disk space. Available: $((AVAIL_KB/1024)) MB, Required: ~$((REQUIRED_KB/1024)) MB"
  exit 1
fi
echo "[✓] Disk space OK: $((AVAIL_KB/1024)) MB available"

# ============ 1. Update System ============
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl wget gnupg2 software-properties-common apt-transport-https

# ============ 2. Install Prometheus ============
PROM_VERSION="3.11.0"
echo "[*] Installing Prometheus v${PROM_VERSION}..."

sudo useradd --no-create-home --shell /bin/false prometheus 2>/dev/null || true
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo chown prometheus:prometheus /etc/prometheus /var/lib/prometheus

cd "$WORKDIR"
curl -LO "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
tar -xf "prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
cd "prometheus-${PROM_VERSION}.linux-amd64"

sudo cp prometheus promtool /usr/local/bin/
sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool

# NOTE: Prometheus 3.x dropped consoles/ and console_libraries/ from binary releases
sudo cp prometheus.yml /etc/prometheus/prometheus.yml
sudo chown -R prometheus:prometheus /etc/prometheus/

# Cleanup immediately to free space before next download
cd "$WORKDIR" && rm -rf "prometheus-${PROM_VERSION}.linux-amd64" "prometheus-${PROM_VERSION}.linux-amd64.tar.gz"

sudo tee /etc/systemd/system/prometheus.service > /dev/null <<'EOF'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus/
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now prometheus
echo "[✓] Prometheus installed"

# ============ 3. Install Grafana ============
echo "[*] Installing Grafana..."

sudo mkdir -p /etc/apt/keyrings
sudo wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
sudo chmod 644 /etc/apt/keyrings/grafana.asc

echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list

sudo apt-get update
sudo apt-get install -y grafana
sudo systemctl enable --now grafana-server
echo "[✓] Grafana installed"

# ============ 4. Install Alertmanager ============
AM_VERSION="0.32.0"
echo "[*] Installing Alertmanager v${AM_VERSION}..."

sudo useradd --no-create-home --shell /bin/false alertmanager 2>/dev/null || true
sudo mkdir -p /etc/alertmanager /var/lib/alertmanager
sudo chown alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager

cd "$WORKDIR"
curl -LO "https://github.com/prometheus/alertmanager/releases/download/v${AM_VERSION}/alertmanager-${AM_VERSION}.linux-amd64.tar.gz"
tar -xf "alertmanager-${AM_VERSION}.linux-amd64.tar.gz"
cd "alertmanager-${AM_VERSION}.linux-amd64"

sudo cp alertmanager amtool /usr/local/bin/
sudo chown alertmanager:alertmanager /usr/local/bin/alertmanager /usr/local/bin/amtool

# Cleanup
cd "$WORKDIR" && rm -rf "alertmanager-${AM_VERSION}.linux-amd64" "alertmanager-${AM_VERSION}.linux-amd64.tar.gz"

sudo tee /etc/systemd/system/alertmanager.service > /dev/null <<'EOF'
[Unit]
Description=Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=alertmanager
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager/
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable alertmanager
echo "[✓] Alertmanager installed"

# ============ 5. Configure PagerDuty Alertmanager ============
sudo tee /etc/alertmanager/alertmanager.yml > /dev/null <<'EOF'
route:
  receiver: pagerduty
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h

receivers:
  - name: pagerduty
    pagerduty_configs:
      - routing_key: "19b0ebd3d6ad4f08d08209b0040d8dcc"  # <-- Replace with your key
        severity: "critical"
EOF

sudo chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager
sudo systemctl start alertmanager

# ============ 6. Configure Prometheus Alert Rules ============
sudo tee /etc/prometheus/alert.rules.yml > /dev/null <<'EOF'
groups:
  - name: example-alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Instance {{ $labels.instance }} is down"
          description: "Prometheus target {{ $labels.instance }} has been unreachable for more than 1 minute."

      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 40
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"
          description: "CPU usage > 40% for more than 2 minutes. VALUE = {{ $value }}%"

      - alert: UnauthorizedRequests
        expr: increase(http_requests_total{status=~"401|403"}[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Unauthorized requests on {{ $labels.instance }}"
          description: "Detected unauthorized (401/403) requests in the past 5 minutes."

      - alert: HighDiskUsage
        expr: >
          (1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}
          / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})) * 100 > 80
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High Disk Usage on {{ $labels.instance }}"
          description: "Disk usage above 80% for more than 2 minutes. VALUE = {{ $value }}%"
EOF

sudo chown prometheus:prometheus /etc/prometheus/alert.rules.yml

# ============ 7. Install Node Exporter ============
NE_VERSION="1.11.1"
echo "[*] Installing Node Exporter v${NE_VERSION}..."

sudo useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true

cd "$WORKDIR"
curl -LO "https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
tar -xf "node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
cd "node_exporter-${NE_VERSION}.linux-amd64"

sudo cp node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

# Cleanup
cd "$WORKDIR" && rm -rf "node_exporter-${NE_VERSION}.linux-amd64" "node_exporter-${NE_VERSION}.linux-amd64.tar.gz"

sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<'EOF'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
echo "[✓] Node Exporter installed"

# ============ 8. Final Prometheus Config ============
sudo tee /etc/prometheus/prometheus.yml > /dev/null <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]
    - ec2_sd_configs:
        - region: us-east-1
          port: 9093
          filters:
            - name: "tag:Name"
              values: ["node-server"]
      relabel_configs:
        - source_labels: [__meta_ec2_private_ip]
          regex: (.*)
          target_label: __address__
          replacement: "$1:9093"

rule_files:
  - "alert.rules.yml"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node-local"
    static_configs:
      - targets: ["localhost:9100"]

  - job_name: "ec2-node-exporters"
    ec2_sd_configs:
      - region: us-east-1
        port: 9100
        filters:
          - name: "tag:Name"
            values: ["node-server"]
    relabel_configs:
      - source_labels: [__meta_ec2_private_ip]
        regex: (.*)
        target_label: __address__
        replacement: "$1:9100"
EOF

sudo chown prometheus:prometheus /etc/prometheus/prometheus.yml

# Validate config before restarting
sudo /usr/local/bin/promtool check config /etc/prometheus/prometheus.yml

sudo systemctl restart prometheus

# ============ 9. Cleanup working directory ============
rm -rf "$WORKDIR"

# ============ 10. Final Status Check ============
echo ""
echo "=============================="
echo " Service Status"
echo "=============================="
for svc in prometheus grafana-server alertmanager node_exporter; do
  STATUS=$(sudo systemctl is-active "$svc" 2>/dev/null || echo "failed")
  echo "  $svc: $STATUS"
done

echo ""
echo "=============================="
echo " Installation Completed ✅"
echo "=============================="
echo ""
echo " Access Points:"
echo "  Grafana       →  http://<your-ip>:3000  (admin / admin)"
echo "  Prometheus    →  http://<your-ip>:9090"
echo "  Alertmanager  →  http://<your-ip>:9093"
echo "  Node Exporter →  http://<your-ip>:9100/metrics"
echo ""
echo " ⚠️  Update PagerDuty key: sudo nano /etc/alertmanager/alertmanager.yml"
echo "=============================="
