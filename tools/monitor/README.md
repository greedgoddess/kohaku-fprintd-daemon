# cros-fprintd-monitor: availability log for debugging

A small agent that records when (and hints why) the fingerprint reader is unavailable, for example when `sudo` or the lock screen don't offer fingerprint after a suspend. It's a development tool and isn't part of the release.

It writes one compact timeline to `/var/log/cros-fprintd-monitor.log` (rotated at 2 MB):

| Line | Content |
|---|---|
| `STATE` | Snapshot whenever something changes (otherwise hourly): service state and restarts, D-Bus name owner, whether the daemon answers (`api`), `/dev/cros_fp`, MCU hello, seed bit, MCU mode, sleep mode. Starts with `avail=yes` or `avail=NO(reasons)` |
| `EVENT` | Every suspend and resume, with the S0ix residency gained during the sleep; extra snapshots 3, 15 and 60 s after waking |
| `JOURNAL` | Matching journal lines: the daemon (including refused requests such as `AlreadyInUse`), `pam_fprintd`, EC errors (`EC failed to respond`), GNOME Shell/GDM fingerprint messages, suspend entry/exit |
| `MARK` | Your own note, with a snapshot |

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

## Remove

```bash
sudo systemctl disable --now cros-fprintd-monitor
sudo rm /usr/local/libexec/cros-fprintd-monitor /etc/systemd/system/cros-fprintd-monitor.service
sudo systemctl daemon-reload
```
