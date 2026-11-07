# cros-fprintd-monitor: availability log for debugging

A small agent that records when (and hints why) the fingerprint reader is unavailable, for example when `sudo` or the lock screen don't offer fingerprint after a suspend. It's a development tool and isn't part of the release.

It writes one compact timeline to `/var/log/cros-fprintd-monitor.log` (rotated at 2 MB):

| Line | Content |
|---|---|
| `STATE` | Snapshot whenever something changes (otherwise hourly): service state and restarts, D-Bus name owner, whether the daemon answers (`api`), `/dev/cros_fp`, MCU hello, seed bit, MCU mode, sleep mode. Starts with `avail=yes` or `avail=NO(reasons)` |
| `EVENT` | Every suspend and resume. The resume line summarises the sleep: duration, share of it in S0ix, battery before and after, average power drawn, and the standby time from a full battery that this rate implies. Extra snapshots follow 3, 15 and 60 s after waking |
| `JOURNAL` | Matching journal lines: the daemon (including refused requests such as `AlreadyInUse`), `pam_fprintd`, EC errors (`EC failed to respond`), GNOME Shell/GDM fingerprint messages, suspend entry/exit |
| `MARK` | Your own note, with a snapshot |
| `SLEEP` | One machine-readable line per suspend: duration, battery energy and percentage before and after, whether external power was connected, seconds spent in S0ix |

The MCU only receives read-only commands (hello, mode query, encryption status).

## Install

From the repository root:

```bash
sudo install -m 0755 tools/monitor/cros-fprintd-monitor /usr/local/libexec/cros-fprintd-monitor
sudo install -m 0644 tools/monitor/cros-fprintd-monitor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cros-fprintd-monitor
sudo /usr/local/libexec/cros-fprintd-monitor status      # should start with avail=yes
```

## Use

When the fingerprint option is missing, mark the moment as soon as possible:

```bash
sudo /usr/local/libexec/cros-fprintd-monitor mark "sudo without fingerprint"
```

Then read the log around the markers:

```bash
sudo tail -n 150 /var/log/cros-fprintd-monitor.log
```

How to read typical findings:

- **`AlreadyInUse` in a `JOURNAL` line:** another client (often the lock screen after resume) still had the reader claimed.
- **`mcu=TIMEOUT` after a resume:** the MCU didn't come back from that suspend.
- **`api=TIMEOUT`:** the daemon was frozen.
- **A changed `pid`, or rising `restarts`:** the daemon crashed and restarted.
- **`avail=yes` at a marker:** the reader and daemon were fine, so look at GNOME or PAM.

## Battery drain while asleep

Every suspend is measured. The monitor holds a short logind "delay" lock, so it can read the battery and the S0ix counter just before the laptop goes to sleep; it releases the lock straight away. For an average over all logged sleeps:

```bash
sudo /usr/local/libexec/cros-fprintd-monitor battery
```

This prints the last sleeps and the average standby power. It also prints the share of sleep time spent in S0ix, and the expected standby time from a full battery. Sleeps shorter than 10 minutes, and sleeps with the charger connected, are left out. One overnight suspend on battery gives a usable first figure. As a rough guide, a healthy S0ix sleep spends nearly all of its time in S0ix; a low share means something kept the platform awake.

## Remove

```bash
sudo systemctl disable --now cros-fprintd-monitor
sudo rm /usr/local/libexec/cros-fprintd-monitor /etc/systemd/system/cros-fprintd-monitor.service
sudo systemctl daemon-reload
```
