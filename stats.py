import os
import json
import time
import signal
import sys
import subprocess
import smbus2
from PIL import Image, ImageDraw, ImageFont

I2C_BUS        = 1
I2C_ADDR       = __ADDR__
DISPLAY_WIDTH  = __WIDTH__
DISPLAY_HEIGHT = __HEIGHT__
SHOW_TEMP      = __SHOW_TEMP__
EXTRA_DISKS    = [d.strip() for d in "__EXTRA_DISKS__".split(',') if d.strip()]
DISK_LABELS    = [l.strip() for l in "__DISK_LABELS__".split(',') if l.strip()]
DISK_UNIT      = "__DISK_UNIT__"

REFRESH_SECS    = 2
DISK_CYCLE_SECS = 10

FONT_PATH   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "PixelOperator.ttf")
CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")


def load_config():
    defaults = {"refresh_secs": REFRESH_SECS, "disk_mode": "rotate",
                "disk_index": 0, "disk_speed": DISK_CYCLE_SECS}
    try:
        with open(CONFIG_PATH) as f:
            return {**defaults, **json.load(f)}
    except Exception:
        return defaults


class SSD1306:
    def __init__(self, bus_num, addr, width, height):
        self._bus = smbus2.SMBus(bus_num)
        self._addr = addr
        self.width = width
        self.height = height
        self._buf = bytearray(width * height // 8)
        self._init_display()

    def _cmd(self, *cmds):
        msg = smbus2.i2c_msg.write(self._addr, bytes([0x00]) + bytes(cmds))
        self._bus.i2c_rdwr(msg)

    def _init_display(self):
        self._cmd(
            0xAE,
            0xD5, 0x80,
            0xA8, self.height - 1,
            0xD3, 0x00,
            0x40,
            0x8D, 0x14,
            0x20, 0x00,
            0xA1,
            0xC8,
            0xDA, 0x12,
            0x81, 0xCF,
            0xD9, 0xF1,
            0xDB, 0x40,
            0xA4,
            0xA6,
            0x2E,
            0xAF,
        )

    def fill(self, val):
        fill_byte = 0xFF if val else 0x00
        self._buf[:] = bytearray([fill_byte] * len(self._buf))

    def image(self, img):
        img = img.convert("1")
        buf = self._buf
        w = self.width
        for page in range(self.height // 8):
            base_row = page * 8
            for col in range(w):
                byte = 0
                for bit in range(8):
                    if img.getpixel((col, base_row + bit)):
                        byte |= 1 << bit
                buf[page * w + col] = byte

    def show(self):
        self._cmd(
            0x21, 0, self.width - 1,
            0x22, 0, self.height // 8 - 1,
        )
        msg = smbus2.i2c_msg.write(self._addr, bytes([0x40]) + bytes(self._buf))
        self._bus.i2c_rdwr(msg)

    def close(self):
        self._bus.close()


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


_prev_cpu_times = None

def get_cpu():
    global _prev_cpu_times
    try:
        with open("/proc/stat") as f:
            fields = f.readline().split()
        times = [int(x) for x in fields[1:]]
        idle = times[3]
        total = sum(times)
        if _prev_cpu_times is not None:
            prev_idle, prev_total = _prev_cpu_times
            idle_delta = idle - prev_idle
            total_delta = total - prev_total
            usage = (1.0 - idle_delta / total_delta) * 100 if total_delta else 0.0
            result = f"{usage:.1f}"
        else:
            result = "?"
        _prev_cpu_times = (idle, total)
        return result
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
    oled.close()
    sys.exit(0)


def main():
    oled = SSD1306(I2C_BUS, I2C_ADDR, DISPLAY_WIDTH, DISPLAY_HEIGHT)

    signal.signal(signal.SIGTERM, lambda *a: blank_and_exit(oled))
    signal.signal(signal.SIGINT,  lambda *a: blank_and_exit(oled))

    font  = ImageFont.truetype(FONT_PATH, 16)
    image = Image.new("1", (DISPLAY_WIDTH, DISPLAY_HEIGHT))
    draw  = ImageDraw.Draw(image)

    boot_label = "BOOT" if EXTRA_DISKS else "DSK"
    if DISK_LABELS and len(DISK_LABELS) == len(EXTRA_DISKS):
        extra = list(zip(DISK_LABELS, EXTRA_DISKS))
    else:
        extra = [(f"D{i}", m) for i, m in enumerate(EXTRA_DISKS, 1)]
    all_disks = [(boot_label, "/")] + extra

    cfg        = load_config()
    refresh    = max(1, min(60,  int(cfg["refresh_secs"])))
    disk_mode  = cfg["disk_mode"]
    disk_index = int(cfg["disk_index"])
    disk_speed = max(1, min(120, int(cfg["disk_speed"])))

    while True:
        draw.rectangle((0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT), outline=0, fill=0)
        y = 0

        draw.text((0, y), f"IP: {get_ip()}", font=font, fill=255)
        y += 16

        cpu = get_cpu()
        if SHOW_TEMP:
            draw.text((0, y), f"CPU:{cpu:>5}%  {get_temp()}", font=font, fill=255)
        else:
            draw.text((0, y), f"CPU: {cpu}%", font=font, fill=255)
        y += 16

        draw.text((0, y), f"MEM: {get_ram()}", font=font, fill=255)
        y += 16

        if disk_mode == "rotate":
            idx = int(time.monotonic() // disk_speed) % len(all_disks)
        else:
            idx = min(disk_index, len(all_disks) - 1)
        label, mount = all_disks[idx]
        draw.text((0, y), f"{label}: {get_disk(mount)}", font=font, fill=255)

        oled.image(image)
        oled.show()
        time.sleep(refresh)


if __name__ == "__main__":
    main()
