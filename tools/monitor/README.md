# cros-fprintd-monitor

A development tool, not part of the release. It logs when and why the reader becomes unavailable, and how much battery each suspend uses. The log is `/var/log/cros-fprintd-monitor.log`, rotated at 2 MB. The chip only receives read-only commands.

The log has these line types:

| Line | Content |
|---|---|
| `STATE` | A snapshot on every change (at least hourly): service, D-Bus owner, API, device, chip, seed, mode and sleep mode. It starts with `avail=yes` or `avail=NO(reasons)` |
| `EVENT` | Each suspend and resume, with duration, share of time in S0ix, battery used and implied standby time |
| `JOURNAL` | Relevant journal lines: the daemon, `pam_fprintd`, EC errors, GNOME fingerprint messages |
| `MARK` | Your own notes |
| `SLEEP` | Machine-readable data for each suspend, used by `battery` |

## Install and use

```bash
sudo install -m 0755 tools/monitor/cros-fprintd-monitor /usr/local/libexec/
sudo install -m 0644 tools/monitor/cros-fprintd-monitor.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now cros-fprintd-monitor

m=/usr/local/libexec/cros-fprintd-monitor
sudo $m status                        # current state, should start with avail=yes
sudo $m mark "no fingerprint prompt"  # note a problem as it happens
sudo $m battery                       # average standby drain (sleeps on battery, 10+ min)
sudo tail -n 150 /var/log/cros-fprintd-monitor.log
```

Typical findings in the log:

- **`AlreadyInUse`:** another client held the reader.
- **`mcu=TIMEOUT`:** the chip didn't come back after a resume.
- **`api=TIMEOUT`:** the daemon hung.
- **A changed `pid`:** the daemon restarted.
- **`avail=yes` at a mark:** look at GNOME or PAM instead.

To remove it:

```bash
sudo systemctl disable --now cros-fprintd-monitor
sudo rm /usr/local/libexec/cros-fprintd-monitor /etc/systemd/system/cros-fprintd-monitor.service
```
