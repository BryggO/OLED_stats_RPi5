#!/usr/bin/env bash
set -euo pipefail

OLED_I2C_ADDR="${OLED_I2C_ADDR:-0x3C}"
OLED_WIDTH="${OLED_WIDTH:-128}"
OLED_HEIGHT="${OLED_HEIGHT:-64}"
SHOW_TEMP="${SHOW_TEMP:-True}"
EXTRA_DISKS="${EXTRA_DISKS:-}"
DISK_LABELS="${DISK_LABELS:-}"
DISK_UNIT="${DISK_UNIT:-}"
OFF_TIME="${OFF_TIME:-22:00}"
ON_TIME="${ON_TIME:-07:15}"

REAL_USER="${SUDO_USER:-pi}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
VENV_DIR="${REAL_HOME}/stats_env"
INSTALL_DIR="${REAL_HOME}/oled-stats"
SYSTEMCTL="$(command -v systemctl)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> OLED stats installer — running for user: ${REAL_USER}"

# --- Interactive disk setup (skipped if EXTRA_DISKS already set via env var) ---
if [ -z "$EXTRA_DISKS" ]; then
    echo ""
    echo "==> Detecting mounted drives..."
    echo ""

    declare -a MOUNTS
    declare -a DEVNAMES
    COUNT=0
    while IFS= read -r line; do
        dev=$(awk '{print $1}'   <<< "$line")
        size=$(awk '{print $2}'  <<< "$line")
        used=$(awk '{print $3}'  <<< "$line")
        avail=$(awk '{print $4}' <<< "$line")
        mount=$(awk '{print $6}' <<< "$line")
        COUNT=$((COUNT+1))
        MOUNTS[$COUNT]="$mount"
        DEVNAMES[$COUNT]="$dev"
        printf "  [%d] %-28s %s  (%s used, %s free)\n" \
            "$COUNT" "$mount" "$size" "$used" "$avail"
    done < <(df -h | awk 'NR>1 && $1 ~ /^\/dev\// && $6 != "/" && $6 !~ /^\/boot/')

    if [ "$COUNT" -eq 0 ]; then
        echo "  (no extra drives detected — only boot disk will be shown)"
    else
        echo ""
        echo "  Boot disk (/) is always shown."
        echo "  Which extra drives to monitor? Enter numbers separated by commas (e.g. 1,2)"
        echo "  Leave blank for boot disk only:"
        printf "  > "
        read -r SELECTION < /dev/tty

        if [ -n "$SELECTION" ]; then
            IFS=',' read -ra NUMS <<< "$SELECTION"
            for num in "${NUMS[@]}"; do
                num=$(echo "$num" | tr -d ' ')
                mount="${MOUNTS[$num]}"
                dev="${DEVNAMES[$num]}"
                echo ""
                echo "  Label for '$mount' ($dev)"
                echo "  Max 8 characters, no commas (e.g. NVMe1, Films, Backup):"
                printf "  > "
                read -r label < /dev/tty
                label="${label//,/}"
                label="${label:0:8}"
                EXTRA_DISKS="${EXTRA_DISKS}${mount},"
                DISK_LABELS="${DISK_LABELS}${label},"
            done
            EXTRA_DISKS="${EXTRA_DISKS%,}"
            DISK_LABELS="${DISK_LABELS%,}"
        fi
    fi

    echo ""
    echo "  Show disk sizes in:"
    echo "  [1] Auto — G below 1 TiB, T at or above  (default)"
    echo "  [2] Always GB"
    echo "  [3] Always TB"
    printf "  > "
    read -r UNIT_CHOICE < /dev/tty
    case "$UNIT_CHOICE" in
        2) DISK_UNIT="G" ;;
        3) DISK_UNIT="T" ;;
        *) DISK_UNIT="auto" ;;
    esac
fi

DISK_UNIT="${DISK_UNIT:-auto}"
echo ""

# 1. System update
apt-get update
apt-get upgrade -y

# 2. pip + venv + setuptools
apt-get install -y python3-pip python3-venv
pip3 install --upgrade setuptools --break-system-packages

# 3. Virtual environment
sudo -u "$REAL_USER" python3 -m venv "$VENV_DIR" --system-site-packages

# 4. Enable I2C
if command -v raspi-config &>/dev/null; then
    raspi-config nonint do_i2c 0
else
    if ! grep -q "dtparam=i2c_arm=on" /boot/firmware/config.txt 2>/dev/null; then
        echo "dtparam=i2c_arm=on" >> /boot/firmware/config.txt
    fi
    modprobe i2c-dev
fi
apt-get install -y i2c-tools

# 5. smbus2 for I2C (no lgpio/adafruit-blinka needed)
sudo -u "$REAL_USER" "$VENV_DIR/bin/pip3" install smbus2

# 6. PIL
apt-get install -y python3-pil

# 7. Copy stats.py and font from repo, then substitute config values
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/stats.py" "$INSTALL_DIR/stats.py"
cp "$SCRIPT_DIR/PixelOperator.ttf" "$INSTALL_DIR/PixelOperator.ttf"

sed -i "s|__ADDR__|${OLED_I2C_ADDR}|g"         "$INSTALL_DIR/stats.py"
sed -i "s|__WIDTH__|${OLED_WIDTH}|g"            "$INSTALL_DIR/stats.py"
sed -i "s|__HEIGHT__|${OLED_HEIGHT}|g"          "$INSTALL_DIR/stats.py"
sed -i "s|__SHOW_TEMP__|${SHOW_TEMP}|g"         "$INSTALL_DIR/stats.py"
sed -i "s|__EXTRA_DISKS__|${EXTRA_DISKS}|g"     "$INSTALL_DIR/stats.py"
sed -i "s|__DISK_LABELS__|${DISK_LABELS}|g"     "$INSTALL_DIR/stats.py"
sed -i "s|__DISK_UNIT__|${DISK_UNIT}|g"         "$INSTALL_DIR/stats.py"
chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"

# 8. Default config.json
OFF_HHMM="${OFF_TIME/:/}"
ON_HHMM="${ON_TIME/:/}"
cat > "$INSTALL_DIR/config.json" << CFGEOF
{
  "refresh_secs": 2,
  "disk_mode": "rotate",
  "disk_index": 0,
  "disk_speed": 10,
  "sleep_time": "${OFF_HHMM}",
  "awake_time": "${ON_HHMM}"
}
CFGEOF
chown "$REAL_USER:$REAL_USER" "$INSTALL_DIR/config.json"

# 9. cron helper (root-owned, called via sudo)
cat > /usr/local/sbin/oled-set-cron << 'CRONEOF'
#!/bin/bash
OFF="$(printf '%04d' "${1}")" ON="$(printf '%04d' "${2}")"
printf '%s %s * * *  root  /usr/bin/systemctl stop oled-stats\n'  "${OFF:2:2}" "${OFF:0:2}" >  /etc/cron.d/oled-stats
printf '%s %s * * *  root  /usr/bin/systemctl start oled-stats\n' "${ON:2:2}"  "${ON:0:2}"  >> /etc/cron.d/oled-stats
CRONEOF
chmod 755 /usr/local/sbin/oled-set-cron

# 10. Systemd service
cat > /etc/systemd/system/oled-stats.service << SVCEOF
[Unit]
Description=OLED Stats Display
After=network.target

[Service]
User=${REAL_USER}
ExecStart=${VENV_DIR}/bin/python3 ${INSTALL_DIR}/stats.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now oled-stats

# 11. oled command
cat << 'OLEDEOF' > /usr/local/bin/oled
#!/bin/bash
CONFIG="__CONFIG_FILE__"

cfg_set() {
    python3 -c "
import json, sys
key, val = sys.argv[1], sys.argv[2]
try: val = int(val)
except: pass
try:
    cfg = json.load(open('$CONFIG'))
except:
    cfg = {}
cfg[key] = val
json.dump(cfg, open('$CONFIG', 'w'), indent=2)
" "$1" "$2"
}

cfg_get() {
    python3 -c "
import json, sys
key, dflt = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open('$CONFIG'))
    print(cfg.get(key, dflt))
except:
    print(dflt)
" "$1" "$2"
}

ACTION="${1:-toggle}"

case "$ACTION" in
  on)
    sudo systemctl start oled-stats
    ;;
  off)
    sudo systemctl stop oled-stats
    ;;
  restart)
    sudo systemctl restart oled-stats
    ;;
  status)
    if systemctl is-active --quiet oled-stats; then
      echo "OLED ▶ ON"
    else
      echo "OLED ■ OFF"
    fi
    ;;
  toggle)
    if systemctl is-active --quiet oled-stats; then
      sudo systemctl stop oled-stats
    else
      sudo systemctl start oled-stats
    fi
    ;;
  updater)
    val="${2:-}"
    if [[ ! "$val" =~ ^[0-9]+$ ]] || (( val < 1 || val > 60 )); then
      echo "Usage: oled updater <1-60>"; exit 1
    fi
    cfg_set refresh_secs "$val"
    sudo systemctl restart oled-stats
    echo "Update rate set to ${val}s"
    ;;
  disk)
    sub="${2:-}"
    case "$sub" in
      rotate)
        cfg_set disk_mode rotate
        sudo systemctl restart oled-stats
        echo "Disk: auto-rotate"
        ;;
      stable)
        cfg_set disk_mode manual
        cfg_set disk_index 0
        sudo systemctl restart oled-stats
        echo "Disk: locked to root"
        ;;
      speed)
        val="${3:-}"
        if [[ ! "$val" =~ ^[0-9]+$ ]] || (( val < 1 || val > 120 )); then
          echo "Usage: oled disk speed <1-120>"; exit 1
        fi
        cfg_set disk_speed "$val"
        sudo systemctl restart oled-stats
        echo "Disk rotation speed set to ${val}s"
        ;;
      ''|*[!0-9]*)
        echo "Usage: oled disk [stable|rotate|speed <n>|<0-N>]"; exit 1
        ;;
      *)
        cfg_set disk_mode manual
        cfg_set disk_index "$sub"
        sudo systemctl restart oled-stats
        echo "Disk: locked to disk $sub"
        ;;
    esac
    ;;
  sleep)
    val="${2:-}"
    if [[ ! "$val" =~ ^[0-2][0-9][0-5][0-9]$ ]]; then
      echo "Usage: oled sleep <HHMM>  (e.g. 2200)"; exit 1
    fi
    cfg_set sleep_time "$val"
    on="$(cfg_get awake_time 0715)"
    sudo /usr/local/sbin/oled-set-cron "$val" "$on"
    echo "Sleep set to ${val:0:2}:${val:2:2}"
    ;;
  awake)
    val="${2:-}"
    if [[ ! "$val" =~ ^[0-2][0-9][0-5][0-9]$ ]]; then
      echo "Usage: oled awake <HHMM>  (e.g. 0600)"; exit 1
    fi
    cfg_set awake_time "$val"
    off="$(cfg_get sleep_time 2200)"
    sudo /usr/local/sbin/oled-set-cron "$off" "$val"
    echo "Wake set to ${val:0:2}:${val:2:2}"
    ;;
  help)
    echo "oled — OLED stats display control"
    echo ""
    echo "Power:"
    echo "  oled                    Toggle display on/off"
    echo "  oled on                 Start the display"
    echo "  oled off                Stop the display (blanks screen)"
    echo "  oled restart            Restart the service"
    echo "  oled status             Show whether display is on or off"
    echo ""
    echo "Refresh rate:"
    echo "  oled updater <1-60>     Set how often the display updates (seconds)"
    echo ""
    echo "Disk display:"
    echo "  oled disk rotate        Auto-cycle through all disks (default)"
    echo "  oled disk stable        Lock to root disk only"
    echo "  oled disk <0-N>         Lock to a specific disk (0 = root)"
    echo "  oled disk speed <1-120> Set how long each disk is shown (seconds)"
    echo ""
    echo "Schedule:"
    echo "  oled sleep <HHMM>       Set auto-off time  (e.g. oled sleep 2200)"
    echo "  oled awake <HHMM>       Set auto-on time   (e.g. oled awake 0715)"
    ;;
  *)
    echo "Usage: oled [on|off|restart|status|toggle|help]"
    echo "       oled updater <1-60>"
    echo "       oled disk [stable|rotate|speed <1-120>|<0-N>]"
    echo "       oled sleep <HHMM>"
    echo "       oled awake <HHMM>"
    exit 1
    ;;
esac
OLEDEOF
chmod +x /usr/local/bin/oled
sed -i "s|__CONFIG_FILE__|${INSTALL_DIR}/config.json|g" /usr/local/bin/oled

# 12. sudoers
cat > /etc/sudoers.d/oled-stats << SUDOEOF
${REAL_USER} ALL=(ALL) NOPASSWD: ${SYSTEMCTL} start oled-stats, ${SYSTEMCTL} stop oled-stats, ${SYSTEMCTL} restart oled-stats, /usr/local/sbin/oled-set-cron
SUDOEOF
chmod 440 /etc/sudoers.d/oled-stats

# 13. Initial cron schedule
/usr/local/sbin/oled-set-cron "${OFF_HHMM}" "${ON_HHMM}"

echo ""
echo "==> pi-oled-stats installed!"
echo "    Verify I2C:  sudo i2cdetect -y 1  (look for 3c or 3d)"
echo "    Control:     oled on / oled off / oled status"
echo "    Refresh:     oled updater <1-60>"
echo "    Disk:        oled disk [stable|rotate|speed <n>|<0-N>]"
echo "    Schedule:    oled sleep <HHMM> / oled awake <HHMM>"
