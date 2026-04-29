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

## Customise at install time

Pass environment variables before `bash`. All are optional — defaults work out of the box.

```bash
curl -sSL .../install.sh | sudo OLED_LABEL="OssyPi" bash
```

Multiple at once:

```bash
curl -sSL .../install.sh | sudo OLED_LABEL="OssyPi" OFF_TIME="23:00" ON_TIME="08:00" bash
```

| Variable        | Default  | Description                                     |
|-----------------|----------|-------------------------------------------------|
| `OLED_LABEL`    | `MyPi`   | Header text shown on line 1                     |
| `OLED_I2C_ADDR` | `0x3C`   | I2C hex address (`0x3C` or `0x3D` depending on board) |
| `OLED_WIDTH`    | `128`    | Display width in pixels                         |
| `OLED_HEIGHT`   | `64`     | Display height in pixels                        |
| `SHOW_IP`       | `True`   | Show IP address line (`True` or `False`)        |
| `SHOW_TEMP`     | `True`   | Show CPU temp next to CPU % (`True` or `False`) |
| `SHOW_UPTIME`   | `True`   | Show uptime on last line (`True` or `False`)    |
| `OFF_TIME`      | `22:00`  | Scheduled off time, 24h `HH:MM`                |
| `ON_TIME`       | `07:15`  | Scheduled on time, 24h `HH:MM`                 |

> Booleans must be capitalized: `True` / `False`.

## Default display layout

```
[ MyPi ]
IP: 192.168.1.42
CPU: 1.3%  45.1'C
RAM: 34%
DSK: 4.2G/29G 14%
Up:  2 hours, 5 min
```

With `SHOW_IP=False SHOW_UPTIME=False`:

```
[ MyPi ]
CPU: 1.3%  45.1'C
RAM: 34%
DSK: 4.2G/29G 14%
```

With `SHOW_TEMP=False`:

```
[ MyPi ]
IP: 192.168.1.42
CPU: 1.3%
RAM: 34%
DSK: 4.2G/29G 14%
Up:  2 hours, 5 min
```

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

Changes are live within seconds of restart.

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

## What gets installed

| Path | Purpose |
|------|---------|
| `~/stats_env/` | Python venv (Adafruit libraries) |
| `~/oled-stats/stats.py` | Display script — edit to customise |
| `/usr/local/bin/oled` | Toggle command |
| `/etc/systemd/system/oled-stats.service` | Auto-start on boot |
| `/etc/sudoers.d/oled-stats` | Passwordless `oled on/off/restart` |
| `/etc/cron.d/oled-stats` | Scheduled on/off |
