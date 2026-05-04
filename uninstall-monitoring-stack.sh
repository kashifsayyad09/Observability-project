#!/bin/bash
set -e

echo "=============================="
echo " Uninstalling Monitoring Stack"
echo " Prometheus + Grafana + Alertmanager + Node Exporter"
echo "=============================="

# ============ 1. Stop & Disable Services ============
echo "[*] Stopping and disabling services..."

for svc in prometheus grafana-server alertmanager node_exporter; do
  if sudo systemctl is-active --quiet "$svc" 2>/dev/null; then
    sudo systemctl stop "$svc"
    echo "  [✓] Stopped $svc"
  else
    echo "  [~] $svc was not running"
  fi

  if sudo systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    sudo systemctl disable "$svc"
    echo "  [✓] Disabled $svc"
  fi
done

# ============ 2. Remove Systemd Unit Files ============
echo "[*] Removing systemd unit files..."

for unit in prometheus alertmanager node_exporter; do
  FILE="/etc/systemd/system/${unit}.service"
  if [ -f "$FILE" ]; then
    sudo rm -f "$FILE"
    echo "  [✓] Removed $FILE"
  fi
done

sudo systemctl daemon-reload
sudo systemctl reset-failed
echo "[✓] Systemd reloaded"

# ============ 3. Remove Prometheus ============
echo "[*] Removing Prometheus binaries and data..."

sudo rm -f /usr/local/bin/prometheus
sudo rm -f /usr/local/bin/promtool
sudo rm -rf /etc/prometheus
sudo rm -rf /var/lib/prometheus

echo "[✓] Prometheus removed"

# ============ 4. Remove Grafana ============
echo "[*] Removing Grafana..."

if dpkg -l | grep -q grafana; then
  sudo apt-get remove --purge -y grafana
  echo "[✓] Grafana package removed"
else
  echo "[~] Grafana package not found via apt"
fi

# Remove Grafana apt repo
sudo rm -f /etc/apt/sources.list.d/grafana.list
sudo rm -f /etc/apt/keyrings/grafana.asc

# Remove leftover Grafana data
sudo rm -rf /etc/grafana
sudo rm -rf /var/lib/grafana
sudo rm -rf /var/log/grafana

echo "[✓] Grafana fully removed"

# ============ 5. Remove Alertmanager ============
echo "[*] Removing Alertmanager binaries and data..."

sudo rm -f /usr/local/bin/alertmanager
sudo rm -f /usr/local/bin/amtool
sudo rm -rf /etc/alertmanager
sudo rm -rf /var/lib/alertmanager

echo "[✓] Alertmanager removed"

# ============ 6. Remove Node Exporter ============
echo "[*] Removing Node Exporter..."

sudo rm -f /usr/local/bin/node_exporter

echo "[✓] Node Exporter removed"

# ============ 7. Remove System Users ============
echo "[*] Removing dedicated system users..."

for user in prometheus alertmanager node_exporter; do
  if id "$user" &>/dev/null; then
    sudo userdel "$user"
    echo "  [✓] Removed user: $user"
  else
    echo "  [~] User $user not found"
  fi
done

# ============ 8. APT Cleanup ============
echo "[*] Running apt cleanup..."

sudo apt-get update -qq
sudo apt-get autoremove -y
sudo apt-get autoclean -y

echo "[✓] APT cleanup done"

# ============ 9. Remove Working Directory (if leftover) ============
if [ -d "/root/install-tmp" ]; then
  rm -rf /root/install-tmp
  echo "[✓] Removed leftover /root/install-tmp"
fi

# ============ 10. Final Verification ============
echo ""
echo "=============================="
echo " Verifying Removal"
echo "=============================="

ALL_CLEAN=true

for bin in prometheus promtool alertmanager amtool node_exporter; do
  if command -v "$bin" &>/dev/null; then
    echo "  ⚠️  Binary still found: $bin"
    ALL_CLEAN=false
  else
    echo "  [✓] $bin not present"
  fi
done

for dir in /etc/prometheus /var/lib/prometheus /etc/alertmanager /var/lib/alertmanager /etc/grafana /var/lib/grafana; do
  if [ -d "$dir" ]; then
    echo "  ⚠️  Directory still exists: $dir"
    ALL_CLEAN=false
  else
    echo "  [✓] $dir removed"
  fi
done

for svc in prometheus grafana-server alertmanager node_exporter; do
  if sudo systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "  ⚠️  Service still running: $svc"
    ALL_CLEAN=false
  else
    echo "  [✓] $svc not running"
  fi
done

echo ""
echo "=============================="
if [ "$ALL_CLEAN" = true ]; then
  echo " Uninstall Completed ✅ — Everything removed cleanly."
else
  echo " Uninstall Completed ⚠️  — Some items may need manual cleanup (see above)."
fi
echo "=============================="
