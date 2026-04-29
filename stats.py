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


def run(cmd):
    return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL).decode().strip()


def fmt_bytes(n):
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
        # $8 is the idle% field in procps-ng top on Bookworm
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
        return f"{fmt_bytes(used)}/{fmt_bytes(total)}"
    except Exception:
        return "?"


def blank_and_exit(oled, *_):
    oled.fill(0)
    oled.show()
    sys.exit(0)


DISK_CYCLE_SECS = 5


def main():
    i2c  = busio.I2C(board.SCL, board.SDA)
    oled = adafruit_ssd1306.SSD1306_I2C(DISPLAY_WIDTH, DISPLAY_HEIGHT, i2c, addr=I2C_ADDR)

    signal.signal(signal.SIGTERM, lambda *a: blank_and_exit(oled))
    signal.signal(signal.SIGINT,  lambda *a: blank_and_exit(oled))

    font  = ImageFont.load_default()
    image = Image.new("1", (DISPLAY_WIDTH, DISPLAY_HEIGHT))
    draw  = ImageDraw.Draw(image)

    all_disks = [("BOOT" if EXTRA_DISKS else "DSK", "/")] + \
                [(f"D{i}", m) for i, m in enumerate(EXTRA_DISKS, 1)]

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
