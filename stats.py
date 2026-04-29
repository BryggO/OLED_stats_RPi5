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
            draw.text((0, y), f"CPU: {cpu}%  {get_temp()}", font=font, fill=255)
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
