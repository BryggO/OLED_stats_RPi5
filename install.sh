#!/usr/bin/env bash
set -euo pipefail

OLED_LABEL="${OLED_LABEL:-MyPi}"
OLED_I2C_ADDR="${OLED_I2C_ADDR:-0x3C}"
OLED_WIDTH="${OLED_WIDTH:-128}"
OLED_HEIGHT="${OLED_HEIGHT:-64}"
SHOW_IP="${SHOW_IP:-True}"
SHOW_TEMP="${SHOW_TEMP:-True}"
SHOW_UPTIME="${SHOW_UPTIME:-True}"
OFF_TIME="${OFF_TIME:-22:00}"
ON_TIME="${ON_TIME:-07:15}"

REAL_USER="${SUDO_USER:-pi}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
VENV_DIR="${REAL_HOME}/stats_env"
INSTALL_DIR="${REAL_HOME}/oled-stats"
SYSTEMCTL="$(command -v systemctl)"

echo "==> Installing pi-oled-stats for user: ${REAL_USER}"

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

LABEL          = "__LABEL__"
I2C_ADDR       = __ADDR__
DISPLAY_WIDTH  = __WIDTH__
DISPLAY_HEIGHT = __HEIGHT__
SHOW_IP        = __SHOW_IP__
SHOW_TEMP      = __SHOW_TEMP__
SHOW_UPTIME    = __SHOW_UPTIME__


def run(cmd):
    return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL).decode().strip()


def get_ip():
    try:
        return run("hostname -I | awk '{print $1}'")
    except Exception:
        return "N/A"


def get_cpu():
    try:
        return run("top -bn1 | grep 'Cpu(s)' | awk '{printf \"%.1f\", 100 - $(NF-3)}'")
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
        return run("free -m | awk '/Mem:/{printf \"%.0f%%\", $3/$2*100}'")
    except Exception:
        return "?"


def get_disk():
    try:
        return run("df -h / | awk 'NR==2{print $3\"/\"$2\" \"$5}'")
    except Exception:
        return "?"


def get_uptime():
    try:
        return run("uptime -p | sed 's/up //'")
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

    while True:
        draw.rectangle((0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT), outline=0, fill=0)
        y = 0

        draw.text((0, y), f"[ {LABEL} ]", font=font, fill=255)
        y += 10

        if SHOW_IP:
            draw.text((0, y), f"IP: {get_ip()}", font=font, fill=255)
            y += 10

        cpu = get_cpu()
        if SHOW_TEMP:
            draw.text((0, y), f"CPU:{cpu}%  {get_temp()}", font=font, fill=255)
        else:
            draw.text((0, y), f"CPU: {cpu}%", font=font, fill=255)
        y += 10

        draw.text((0, y), f"RAM: {get_ram()}", font=font, fill=255)
        y += 10
        draw.text((0, y), f"DSK: {get_disk()}", font=font, fill=255)
        y += 10

        if SHOW_UPTIME:
            draw.text((0, y), f"Up:  {get_uptime()}", font=font, fill=255)

        oled.image(image)
        oled.show()
        time.sleep(1)


if __name__ == "__main__":
    main()
PYEOF

sed -i "s|__LABEL__|${OLED_LABEL}|g"       "$INSTALL_DIR/stats.py"
sed -i "s|__ADDR__|${OLED_I2C_ADDR}|g"     "$INSTALL_DIR/stats.py"
sed -i "s|__WIDTH__|${OLED_WIDTH}|g"        "$INSTALL_DIR/stats.py"
sed -i "s|__HEIGHT__|${OLED_HEIGHT}|g"      "$INSTALL_DIR/stats.py"
sed -i "s|__SHOW_IP__|${SHOW_IP}|g"         "$INSTALL_DIR/stats.py"
sed -i "s|__SHOW_TEMP__|${SHOW_TEMP}|g"     "$INSTALL_DIR/stats.py"
sed -i "s|__SHOW_UPTIME__|${SHOW_UPTIME}|g" "$INSTALL_DIR/stats.py"
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
