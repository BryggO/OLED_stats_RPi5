# pi-oled-stats

OLED stats display for Raspberry Pi 5. One command installs everything.

## One-liner

```bash
curl -sSL http://<forgejo-host>:3030/HomeLab/pi-oled-stats/raw/branch/main/install.sh | sudo bash
```

With a custom label:

```bash
curl -sSL http://<forgejo-host>:3030/HomeLab/pi-oled-stats/raw/branch/main/install.sh | sudo OLED_LABEL="OssyPi" bash
```

## Hardware

SSD1306-based 128×64 I2C OLED. Wire to GPIO header:

| OLED pin | Pi physical pin |
|----------|----------------|
| GND      | Pin 9          |
| VCC      | Pin 1 (3.3V)   |
| SCL      | Pin 5 (GPIO 3) |
| SDA      | Pin 3 (GPIO 2) |

Verify I2C after install:

```bash
sudo i2cdetect -y 1
```

Look for `3c` or `3d` in the output.

## Environment variables

All optional. Set before the pipe:

| Variable       | Default  | Description                        |
|----------------|----------|------------------------------------|
| `OLED_LABEL`   | `MyPi`   | Header text on display             |
| `OLED_I2C_ADDR`| `0x3C`   | I2C hex address                    |
| `OLED_WIDTH`   | `128`    | Display width in pixels            |
| `OLED_HEIGHT`  | `64`     | Display height in pixels           |
| `SHOW_IP`      | `True`   | Show IP address line               |
| `SHOW_TEMP`    | `True`   | Show CPU temp on CPU line          |
| `SHOW_UPTIME`  | `True`   | Show uptime on last line           |
| `OFF_TIME`     | `22:00`  | Cron: turn display off (24h HH:MM) |
| `ON_TIME`      | `07:15`  | Cron: turn display on (24h HH:MM)  |

## Display layout

```
[ MyPi ]
IP: 192.168.1.42
CPU: 1.3%  45.1'C
RAM: 34%
DSK: 4.2G/29G 14%
Up:  2 hours, 5 min
```

## `oled` command

| Command        | Action                              |
|----------------|-------------------------------------|
| `oled`         | Toggle (on if off, off if on)       |
| `oled on`      | Start the display service           |
| `oled off`     | Stop the display (blanks screen)    |
| `oled restart` | Restart (picks up stats.py changes) |
| `oled status`  | Print `OLED ▶ ON` or `OLED ■ OFF`  |

## Editing stats

```bash
nano ~/oled-stats/stats.py
oled restart
```

## What gets installed

- `~/stats_env/` — Python venv with Adafruit libraries
- `~/oled-stats/stats.py` — display script (edit this to customise)
- `/usr/local/bin/oled` — toggle command
- `/etc/systemd/system/oled-stats.service` — auto-start on boot
- `/etc/sudoers.d/oled-stats` — passwordless oled on/off
- `/etc/cron.d/oled-stats` — scheduled on/off
