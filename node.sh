#!/bin/bash
set -e

echo "=============================="
echo " Installing Alertmanager v0.32.0 + Node Exporter v1.11.1"
echo "=============================="

# ============ 0. System Update ============
echo "[*] Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y

# ============ 1. Install Alertmanager ============
AM_VERSION="0.32.0"

echo "[*] Creating alertmanager user..."
sudo useradd --no-create-home --shell /bin/false alertmanager 2>/dev/null || true

echo "[*] Creating Alertmanager directories..."
sudo mkdir -p /etc/alertmanager /var/lib/alertmanager
sudo chown alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager

echo "[*] Downloading Alertmanager v${AM_VERSION}..."
cd /tmp
curl -LO "https://github.com/prometheus/alertmanager/releases/download/v${AM_VERSION}/alertmanager-${AM_VERSION}.linux-amd64.tar.gz"
tar -xvf "alertmanager-${AM_VERSION}.linux-amd64.tar.gz"
cd "alertmanager-${AM_VERSION}.linux-amd64"

echo "[*] Installing Alertmanager binaries..."
sudo cp alertmanager amtool /usr/local/bin/
sudo chown alertmanager:alertmanager /usr/local/bin/alertmanager /usr/local/bin/amtool

echo "[*] Copying default Alertmanager config..."
sudo cp alertmanager.yml /etc/alertmanager/alertmanager.yml
sudo chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager

# Cleanup
cd /tmp && rm -rf "alertmanager-${AM_VERSION}.linux-amd64" "alertmanager-${AM_VERSION}.linux-amd64.tar.gz"

echo "[*] Creating systemd service for Alertmanager..."
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
sudo systemctl enable --now alertmanager

echo ">>> Alertmanager installed and running on port 9093"

# ============ 2. Install Node Exporter ============
NE_VERSION="1.11.1"

echo "[*] Creating node_exporter user..."
sudo useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true

echo "[*] Downloading Node Exporter v${NE_VERSION}..."
cd /tmp
curl -LO "https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
tar -xvf "node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
cd "node_exporter-${NE_VERSION}.linux-amd64"

echo "[*] Installing Node Exporter binary..."
sudo cp node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

# Cleanup
cd /tmp && rm -rf "node_exporter-${NE_VERSION}.linux-amd64" "node_exporter-${NE_VERSION}.linux-amd64.tar.gz"

echo "[*] Creating systemd service for Node Exporter..."
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

echo ">>> Node Exporter installed and running on port 9100"

# ============ 3. Status Check ============
echo ""
echo "=============================="
echo " Service Status"
echo "=============================="
for svc in alertmanager node_exporter; do
  STATUS=$(sudo systemctl is-active "$svc" 2>/dev/null || echo "failed")
  echo "  $svc: $STATUS"
done

echo ""
echo "=============================="
echo " Installation Completed ✅"
echo "=============================="
echo ""
echo " Access Points:"
echo "  Alertmanager  →  http://<your-ip>:9093"
echo "  Node Exporter →  http://<your-ip>:9100/metrics"
echo "=============================="
