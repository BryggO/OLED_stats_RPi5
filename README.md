# OLED_stats_RPi5

OLED stats display for Raspberry Pi 5. One command installs everything.

> Based on [mklements/OLED_Stats](https://github.com/mklements/OLED_Stats).
> Written with [Claude Code](https://claude.ai/code).
>
> Hosted locally, send me an email for any issues / requests

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
curl -sSL http://<forgejo-host>:3030/HomeLab/OLED_stats_RPi5/raw/branch/main/install.sh | sudo bash
```

**Expect 10–30 minutes.** The script runs `apt-get upgrade` and compiles several Python packages.

### Interactive disk wizard

When no `EXTRA_DISKS` env var is set, the installer detects all mounted drives and lets you pick which to monitor:

```
==> Detecting mounted drives...

  [1] /mnt/nvme0                    1.9T  (120G used, 1.7T free)
  [2] /mnt/nvme1                    1.9T  (80G used, 1.8T free)

  Boot disk (/) is always shown.
  Which extra drives to monitor? Enter numbers separated by commas (e.g. 1,2)
  Leave blank for boot disk only:
  > 1,2

  Label for '/mnt/nvme0' (/dev/nvme0n1p1)
  Max 8 characters, no commas (e.g. NVMe1, Films, Backup):
  > NVMe0

  Label for '/mnt/nvme1' (/dev/nvme0n1p2)
  Max 8 characters, no commas (e.g. NVMe1, Films, Backup):
  > NVMe1

  Show disk sizes in:
  [1] Auto — G below 1 TiB, T at or above  (default)
  [2] Always GB
  [3] Always TB
  > 3
```

To skip the wizard, pass env vars directly (see [Customise at install time](#customise-at-install-time)).

When it finishes you will see:

```
==> pi-oled-stats installed!
    Verify I2C:  sudo i2cdetect -y 1  (look for 3c or 3d)
    Control:     oled on / oled off / oled status
    Refresh:     oled updater <1-60>
    Disk:        oled disk [stable|rotate|speed <n>|<0-N>]
    Schedule:    oled sleep <HHMM> / oled awake <HHMM>
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

Always 4 lines. `SHOW_TEMP=False` removes the temperature from line 2 but line count stays 4.

## Extra drives — disk cycling

When extra drives are configured, line 4 cycles through all drives (10 seconds each by default):

```
second 0–9:   BOOT: 4.0G/29.0G
second 10–19: NVMe0: 0.1T/1.8T
second 20–29: NVMe1: 0.1T/1.8T
second 30–39: BOOT: 4.0G/29.0G  ← loops
```

Use `oled disk` commands to control cycling at any time without reinstalling (see [`oled` command](#oled-command)).

To find your mount points:

```bash
lsblk -o NAME,SIZE,MOUNTPOINT,FSTYPE | grep -v loop
```

## Customise at install time

Pass environment variables before `bash`. All are optional — the interactive wizard handles drive setup if omitted.

```bash
curl -sSL .../install.sh | sudo SHOW_TEMP=False OFF_TIME="23:00" ON_TIME="08:00" bash
```

To skip the wizard entirely and pre-configure drives:

```bash
curl -sSL .../install.sh | sudo \
  EXTRA_DISKS="/mnt/nvme0,/mnt/nvme1" \
  DISK_LABELS="NVMe0,NVMe1" \
  DISK_UNIT="T" \
  bash
```

| Variable        | Default   | Description                                                        |
|-----------------|-----------|--------------------------------------------------------------------|
| `SHOW_TEMP`     | `True`    | Show CPU temp next to CPU% on line 2 (`True` or `False`)          |
| `EXTRA_DISKS`   | _(wizard)_| Comma-separated mount points for extra drives                      |
| `DISK_LABELS`   | _(wizard)_| Comma-separated labels matching `EXTRA_DISKS` (max 8 chars each)  |
| `DISK_UNIT`     | _(wizard)_| Disk size unit: `auto`, `G` (always GB), or `T` (always TB)       |
| `OLED_I2C_ADDR` | `0x3C`    | I2C hex address (`0x3C` or `0x3D` depending on board)             |
| `OLED_WIDTH`    | `128`     | Display width in pixels                                            |
| `OLED_HEIGHT`   | `64`      | Display height in pixels                                           |
| `OFF_TIME`      | `22:00`   | Scheduled off time, 24h `HH:MM`                                   |
| `ON_TIME`       | `07:15`   | Scheduled on time, 24h `HH:MM`                                    |

> Booleans must be capitalized: `True` / `False`.
> `DISK_UNIT=auto` shows G below 1 TiB, T at or above.

## `oled` command

Available immediately after install, no `sudo` needed. Run `oled help` to see all commands.

### Power

| Command        | Action                              |
|----------------|-------------------------------------|
| `oled`         | Toggle (on if off, off if on)       |
| `oled on`      | Start the display service           |
| `oled off`     | Stop the display (blanks screen)    |
| `oled restart` | Restart the service                 |
| `oled status`  | Print `OLED ▶ ON` or `OLED ■ OFF`  |

### Refresh rate

| Command           | Action                                        |
|-------------------|-----------------------------------------------|
| `oled updater 2`  | Update display every 2 seconds (default)      |
| `oled updater 5`  | Update display every 5 seconds                |

Valid range: 1–60 seconds. Persists across reboots.

### Disk display

Disk 0 is always the root (boot) disk. Disk 1, 2, … are the extra drives you configured at install time.

| Command              | Action                                              |
|----------------------|-----------------------------------------------------|
| `oled disk rotate`   | Auto-cycle through all disks (default)              |
| `oled disk stable`   | Lock to root disk only                              |
| `oled disk 0`        | Lock to root disk (same as `stable`)                |
| `oled disk 1`        | Lock to first extra disk                            |
| `oled disk speed 10` | Cycle disks every 10 seconds (default, range 1–120) |

### Schedule

Times are in 24h `HHMM` format (no colon).

| Command             | Action                          |
|---------------------|---------------------------------|
| `oled sleep 2200`   | Turn off display at 22:00       |
| `oled awake 0715`   | Turn on display at 07:15        |

Changes take effect immediately in cron — no restart needed. Settings persist across reboots.

## Editing the display

```bash
nano ~/oled-stats/stats.py
oled restart
```

`EXTRA_DISKS`, `DISK_LABELS`, `DISK_UNIT`, `SHOW_TEMP`, `REFRESH_SECS`, and `DISK_CYCLE_SECS` are plain Python variables at the top of the file. Runtime overrides (set via `oled updater` / `oled disk`) are stored in `~/oled-stats/config.json`.

## Troubleshooting

**Display is blank after install**

```bash
sudo reboot
```

**Check I2C is detected**

```bash
sudo i2cdetect -y 1
```

You should see `3c` (or `3d`) in the grid. All dashes = I2C not active, reboot or check wiring.

**Check service status**

```bash
systemctl status oled-stats
journalctl -u oled-stats -n 50
```

**Wrong I2C address**

If `i2cdetect` shows `3d` instead of `3c`, edit `~/oled-stats/stats.py`, change `I2C_ADDR = 0x3C` to `0x3D`, then `oled restart`.

## What gets installed

| Path | Purpose |
|------|---------|
| `~/stats_env/` | Python venv (smbus2, Pillow) |
| `~/oled-stats/stats.py` | Display script — edit to customise |
| `~/oled-stats/PixelOperator.ttf` | Pixel font for the display |
| `~/oled-stats/config.json` | Runtime settings (refresh rate, disk mode, schedule) |
| `/usr/local/bin/oled` | Control command |
| `/usr/local/sbin/oled-set-cron` | Schedule update helper (root) |
| `/etc/systemd/system/oled-stats.service` | Auto-start on boot |
| `/etc/sudoers.d/oled-stats` | Passwordless `oled` commands |
| `/etc/cron.d/oled-stats` | Scheduled on/off |

## CI

Every push and PR runs `.forgejo/workflows/ci.yml` on the homelab runner: it renders
`stats.py` with sample values (as `install.sh` does), fails on any unfilled
`__PLACEHOLDER__`, then checks syntax (`py_compile`, `bash -n`) and `ruff --select E9,F`.
`main` requires `ci / lint (pull_request)` to pass before a PR can merge.
