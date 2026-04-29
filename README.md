# pi-oled-stats

OLED stats display for Raspberry Pi 5. One command installs everything — no interaction required.

## Hardware

SSD1306-based 128×64 I2C OLED. Wire to GPIO header before running the installer:

| OLED pin | Pi physical pin |
|----------|----------------|
| GND      | Pin 9          |
| VCC      | Pin 1 (3.3V)   |
| SCL      | Pin 5 (GPIO 3) |
| SDA      | Pin 3 (GPIO 2) |

## Install

```bash
curl -sSL http://<forgejo-host>:3030/HomeLab/pi-oled-stats/raw/branch/main/install.sh | sudo bash
```

**Expect 10–30 minutes.** The script runs `apt-get upgrade` and compiles several Python packages.

When it finishes you will see:

```
==> pi-oled-stats installed!
    Verify I2C:  sudo i2cdetect -y 1  (look for 3c or 3d)
    Control:     oled on / oled off / oled status
    Edit:        /home/<user>/oled-stats/stats.py  then  oled restart
```

The display starts immediately. If it stays blank, reboot once — the I2C device tree overlay occasionally needs a full boot cycle to activate:

```bash
sudo reboot
```

## Default display

```
IP: 192.168.1.42
CPU: 1.3%  45.1'C
MEM: 1.7G/7.7G
DSK: 4.0G/29.0G
```

4 lines. Always on. `SHOW_TEMP=False` removes the temperature from line 2 but keeps 4 lines:

```
IP: 192.168.1.42
CPU: 1.3%
MEM: 1.7G/7.7G
DSK: 4.0G/29.0G
```

## Customise at install time

Pass environment variables before `bash`. All are optional — defaults work out of the box.

Single variable:
```bash
curl -sSL .../install.sh | sudo SHOW_TEMP=False bash
```

Multiple:
```bash
curl -sSL .../install.sh | sudo SHOW_TEMP=False OFF_TIME="23:00" ON_TIME="08:00" bash
```

With extra drives (e.g. Pimoroni NVMe Base Duo, drives mounted at `/mnt/d1` and `/mnt/d2`):
```bash
curl -sSL .../install.sh | sudo EXTRA_DISKS="/mnt/d1,/mnt/d2" bash
```

That gives a 6-line layout:
```
IP: 192.168.1.42
CPU: 1.3%  45.1'C
MEM: 1.7G/7.7G
BOOT: 4.0G/29.0G
D1: 0.4T/1.8T
D2: 0.8T/1.8T
```

Sizes are shown in G or T automatically (binary GiB/TiB). Boot disk uses `DSK:` label when no extra disks are configured, `BOOT:` when they are.

## Environment variables

| Variable        | Default  | Description                                             |
|-----------------|----------|---------------------------------------------------------|
| `SHOW_TEMP`     | `True`   | Show CPU temp next to CPU% on line 2 (`True` or `False`) |
| `EXTRA_DISKS`   | _(none)_ | Comma-separated mount points for extra drives           |
| `OLED_I2C_ADDR` | `0x3C`   | I2C hex address (`0x3C` or `0x3D` depending on board)  |
| `OLED_WIDTH`    | `128`    | Display width in pixels                                 |
| `OLED_HEIGHT`   | `64`     | Display height in pixels                                |
| `OFF_TIME`      | `22:00`  | Scheduled off time, 24h `HH:MM`                        |
| `ON_TIME`       | `07:15`  | Scheduled on time, 24h `HH:MM`                         |

> Booleans must be capitalized: `True` / `False`.

## `oled` command

Available immediately after install, no `sudo` needed:

| Command        | Action                              |
|----------------|-------------------------------------|
| `oled`         | Toggle (on if off, off if on)       |
| `oled on`      | Start the display service           |
| `oled off`     | Stop the display (blanks screen)    |
| `oled restart` | Restart — picks up stats.py changes |
| `oled status`  | Print `OLED ▶ ON` or `OLED ■ OFF`  |

## Editing the display

```bash
nano ~/oled-stats/stats.py
oled restart
```

Changes are live within seconds of restart. The `EXTRA_DISKS` list and `SHOW_TEMP` flag are plain Python variables at the top of the file — easy to change without reinstalling.

## Troubleshooting

**Display is blank after install**

```bash
sudo reboot
```

**Check I2C is detected**

```bash
sudo i2cdetect -y 1
```

You should see `3c` (or `3d`) in the grid. If the grid is all dashes, I2C isn't active — reboot or check wiring.

**Check service status**

```bash
systemctl status oled-stats
journalctl -u oled-stats -n 50
```

**Wrong I2C address**

If `i2cdetect` shows `3d` instead of `3c`, reinstall with:

```bash
curl -sSL .../install.sh | sudo OLED_I2C_ADDR="0x3D" bash
```

Or edit `~/oled-stats/stats.py`, change `I2C_ADDR = 0x3C` to `0x3D`, then `oled restart`.

**CPU reads 100%**

On non-Bookworm systems, `top`'s output format may differ. Edit `stats.py` and change the `get_cpu()` shell command. The field `$8` (idle%) is correct for procps-ng 4.x (Bookworm default).

## What gets installed

| Path | Purpose |
|------|---------|
| `~/stats_env/` | Python venv (Adafruit libraries) |
| `~/oled-stats/stats.py` | Display script — edit to customise |
| `/usr/local/bin/oled` | Toggle command |
| `/etc/systemd/system/oled-stats.service` | Auto-start on boot |
| `/etc/sudoers.d/oled-stats` | Passwordless `oled on/off/restart` |
| `/etc/cron.d/oled-stats` | Scheduled on/off |
