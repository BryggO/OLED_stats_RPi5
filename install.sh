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

# 5. Adafruit Blinka
sudo -u "$REAL_USER" "$VENV_DIR/bin/pip3" install --upgrade adafruit-blinka

# 6. SSD1306 library
sudo -u "$REAL_USER" "$VENV_DIR/bin/pip3" install adafruit-circuitpython-ssd1306

# 7. PIL
apt-get install -y python3-pil

# 8. Write stats.py
mkdir -p "$INSTALL_DIR"
cat << 'PYEOF' > "$INSTALL_DIR/stats.py"
import time
import signal
import sys
import subprocess

import board
import busio
from PIL import Image, ImageDraw, ImageFont
import adafruit_ssd1306

I2C_ADDR       = __ADDR__
DISPLAY_WIDTH  = __WIDTH__
DISPLAY_HEIGHT = __HEIGHT__
SHOW_TEMP      = __SHOW_TEMP__
EXTRA_DISKS    = [d.strip() for d in "__EXTRA_DISKS__".split(',') if d.strip()]
DISK_LABELS    = [l.strip() for l in "__DISK_LABELS__".split(',') if l.strip()]
DISK_UNIT      = "__DISK_UNIT__"

DISK_CYCLE_SECS = 5


def run(cmd):
    return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL).decode().strip()


def fmt_bytes(n, unit=None):
    if unit == "T":
        return f"{n / (1 << 40):.1f}T"
    if unit == "G":
        return f"{n / (1 << 30):.1f}G"
    if n >= 1 << 40:
        return f"{n / (1 << 40):.1f}T"
    if n >= 1 << 30:
        return f"{n / (1 << 30):.1f}G"
    return f"{n / (1 << 20):.0f}M"


def get_ip():
    try:
        return run("hostname -I | awk '{print $1}'")
    except Exception:
        return "N/A"


def get_cpu():
    try:
        return run("top -bn1 | grep '%Cpu' | awk '{printf \"%.1f\", 100 - $8}'")
    except Exception:
        return "?"


def get_temp():
    try:
        raw = run("vcgencmd measure_temp 2>/dev/null | cut -d= -f2")
        if raw:
            return raw
    except Exception:
        pass
    try:
        millideg = int(run("cat /sys/class/thermal/thermal_zone0/temp"))
        return f"{millideg / 1000:.1f}'C"
    except Exception:
        return "?"


def get_ram():
    try:
        out = run("free -b | awk '/Mem:/{print $3, $2}'")
        used, total = map(int, out.split())
        return f"{fmt_bytes(used)}/{fmt_bytes(total)}"
    except Exception:
        return "?"


def get_disk(mount):
    try:
        out = run(f"df -B1 {mount} | awk 'NR==2{{print $3, $2}}'")
        used, total = map(int, out.split())
        unit = None if DISK_UNIT == "auto" else DISK_UNIT
        return f"{fmt_bytes(used, unit)}/{fmt_bytes(total, unit)}"
    except Exception:
        return "?"


def blank_and_exit(oled, *_):
    oled.fill(0)
    oled.show()
    sys.exit(0)


def main():
    i2c  = busio.I2C(board.SCL, board.SDA)
    oled = adafruit_ssd1306.SSD1306_I2C(DISPLAY_WIDTH, DISPLAY_HEIGHT, i2c, addr=I2C_ADDR)

    signal.signal(signal.SIGTERM, lambda *a: blank_and_exit(oled))
    signal.signal(signal.SIGINT,  lambda *a: blank_and_exit(oled))

    font  = ImageFont.load_default()
    image = Image.new("1", (DISPLAY_WIDTH, DISPLAY_HEIGHT))
    draw  = ImageDraw.Draw(image)

    boot_label = "BOOT" if EXTRA_DISKS else "DSK"
    if DISK_LABELS and len(DISK_LABELS) == len(EXTRA_DISKS):
        extra = list(zip(DISK_LABELS, EXTRA_DISKS))
    else:
        extra = [(f"D{i}", m) for i, m in enumerate(EXTRA_DISKS, 1)]
    all_disks = [(boot_label, "/")] + extra

    iteration = 0
    while True:
        draw.rectangle((0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT), outline=0, fill=0)
        y = 0

        draw.text((0, y), f"IP: {get_ip()}", font=font, fill=255)
        y += 10

        cpu = get_cpu()
        if SHOW_TEMP:
            draw.text((0, y), f"CPU: {cpu}%  {get_temp()}", font=font, fill=255)
        else:
            draw.text((0, y), f"CPU: {cpu}%", font=font, fill=255)
        y += 10

        draw.text((0, y), f"MEM: {get_ram()}", font=font, fill=255)
        y += 10

        label, mount = all_disks[(iteration // DISK_CYCLE_SECS) % len(all_disks)]
        draw.text((0, y), f"{label}: {get_disk(mount)}", font=font, fill=255)

        oled.image(image)
        oled.show()
        iteration += 1
        time.sleep(1)


if __name__ == "__main__":
    main()
PYEOF

sed -i "s|__ADDR__|${OLED_I2C_ADDR}|g"         "$INSTALL_DIR/stats.py"
sed -i "s|__WIDTH__|${OLED_WIDTH}|g"            "$INSTALL_DIR/stats.py"
sed -i "s|__HEIGHT__|${OLED_HEIGHT}|g"          "$INSTALL_DIR/stats.py"
sed -i "s|__SHOW_TEMP__|${SHOW_TEMP}|g"         "$INSTALL_DIR/stats.py"
sed -i "s|__EXTRA_DISKS__|${EXTRA_DISKS}|g"     "$INSTALL_DIR/stats.py"
sed -i "s|__DISK_LABELS__|${DISK_LABELS}|g"     "$INSTALL_DIR/stats.py"
sed -i "s|__DISK_UNIT__|${DISK_UNIT}|g"         "$INSTALL_DIR/stats.py"
chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"

# 9. Systemd service
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

# 10. oled command + sudoers
cat << 'OLEDEOF' > /usr/local/bin/oled
#!/bin/bash
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
  *)
    echo "Usage: oled [on|off|restart|status]"
    exit 1
    ;;
esac
OLEDEOF
chmod +x /usr/local/bin/oled

cat > /etc/sudoers.d/oled-stats << SUDOEOF
${REAL_USER} ALL=(ALL) NOPASSWD: ${SYSTEMCTL} start oled-stats, ${SYSTEMCTL} stop oled-stats, ${SYSTEMCTL} restart oled-stats
SUDOEOF
chmod 440 /etc/sudoers.d/oled-stats

# 11. Cron schedule
OFF_H="${OFF_TIME%%:*}"
OFF_M="${OFF_TIME##*:}"
ON_H="${ON_TIME%%:*}"
ON_M="${ON_TIME##*:}"

cat > /etc/cron.d/oled-stats << CRONEOF
${OFF_M} ${OFF_H} * * *  root  ${SYSTEMCTL} stop oled-stats
${ON_M} ${ON_H} * * *  root  ${SYSTEMCTL} start oled-stats
CRONEOF

echo ""
echo "==> pi-oled-stats installed!"
echo "    Verify I2C:  sudo i2cdetect -y 1  (look for 3c or 3d)"
echo "    Control:     oled on / oled off / oled status"
echo "    Edit:        ${INSTALL_DIR}/stats.py  then  oled restart"
