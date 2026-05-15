#!/bin/bash
set -e

echo "=============================="
echo " Installing Prometheus + Grafana + Node Exporter"
echo " Versions: Prometheus 3.11.0 | Node Exporter 1.11.1 | Grafana 13.x"
echo " Target: Amazon Linux / RHEL"
echo "=============================="

# ============ 0. Pre-flight: Disk Space Check ============
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
sudo dnf update -y
sudo dnf install -y wget
# Note: curl-minimal is pre-installed on Amazon Linux 2023 and works fine.
# Do NOT install 'curl' (full package) — it conflicts with curl-minimal.

# ============ 2. Install Prometheus ============
PROM_VERSION="3.11.0"
echo "[*] Installing Prometheus v${PROM_VERSION}..."

sudo useradd --no-create-home --shell /sbin/nologin prometheus 2>/dev/null || true
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

sudo tee /etc/yum.repos.d/grafana.repo > /dev/null <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF

sudo dnf install -y grafana
sudo systemctl enable --now grafana-server
echo "[✓] Grafana installed"

# ============ 4. Configure Prometheus Alert Rules ============
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

# ============ 5. Install Node Exporter ============
NE_VERSION="1.11.1"
echo "[*] Installing Node Exporter v${NE_VERSION}..."

sudo useradd --no-create-home --shell /sbin/nologin node_exporter 2>/dev/null || true

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

# ============ 6. Final Prometheus Config ============
sudo tee /etc/prometheus/prometheus.yml > /dev/null <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "alert.rules.yml"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node-local"
    static_configs:
      - targets: ["localhost:9100"]

  - job_name: "ec2-backend-auto"
    ec2_sd_configs:
      - region: us-east-1
        port: 9100
        filters:
          - name: "tag:Name"
            values: ["Backend-Auto"]
    relabel_configs:
      - source_labels: [__meta_ec2_private_ip]
        regex: (.*)
        target_label: __address__
        replacement: "$1:9100"

  - job_name: "ec2-frontend-auto"
    ec2_sd_configs:
      - region: us-east-1
        port: 9100
        filters:
          - name: "tag:Name"
            values: ["Frontend-Auto"]
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

# ============ 7. AWS Security Group (Managed externally) ============
# Firewall is managed via AWS Security Groups — no firewalld config needed.
# Ensure the following inbound rules are set in your Security Group:
#
#   Port 3000  (TCP) — Grafana        → your IP or 0.0.0.0/0
#   Port 9090  (TCP) — Prometheus     → your IP or internal CIDR
#   Port 9100  (TCP) — Node Exporter  → Prometheus server IP / internal CIDR
#
echo "[✓] Skipping firewalld — using AWS Security Groups for port access"

# ============ 8. Cleanup working directory ============
rm -rf "$WORKDIR"

# ============ 9. Final Status Check ============
echo ""
echo "=============================="
echo " Service Status"
echo "=============================="
for svc in prometheus grafana-server node_exporter; do
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
echo "  Node Exporter →  http://<your-ip>:9100/metrics"
echo "=============================="
