# kohaku-fprintd-daemon

Fingerprint unlock for the **Samsung Galaxy Chromebook (Kohaku)** on Fedora with MrChromebox firmware. `sudo`, the GNOME lock screen and the `fprintd-*` tools use the built-in reader.

The daemon, `cros-fprintd`, provides the standard `fprintd` D-Bus API and talks to the ChromeOS fingerprint chip through `/dev/cros_fp`.

## Before you install

- **Experimental and pre-1.0.** It was built for and tested on one laptop: Kohaku, MrChromebox 2609.3, Fedora 45, GNOME Shell 51. It isn't regularly maintained; forks are welcome.
- **It runs as root and changes your PAM configuration.** Keep a root shell open while you enable fingerprint. Your password always remains a fallback.
- **Not security-audited.** Treat fingerprint as a convenience, not as your only protection.
- **Written largely by an AI assistant** (Claude, by Anthropic), directed and tested on the hardware by the author. It has had no independent review, so read `install.sh` and `cros-fprintd` before running them as root.

## Requirements

The installer checks these and refuses to install otherwise:

- Kohaku with a working reader (`/dev/cros_fp`).
- MrChromebox firmware **2609.3 or newer**, with the **S0ix** option enabled in the firmware setup (press ESC at boot). Firmware updates reset that option.
- s2idle as the sleep mode, with working S0ix. The installer runs a 20-second test suspend if S0ix hasn't been reached since boot.

**Deep sleep (S3) isn't supported:** after it, the reader stays off until a full power-off ([details](docs/SUSPEND.md)).

**Other fingerprint readers, such as USB readers, don't work while this is installed,** because the stock `fprintd` gets masked. If such a reader is connected, the installer asks first.

## What works

- ✅ Enrolment and verification, `sudo`, the GNOME lock screen, fingerprint after suspend.
- Untested: polkit prompts, and fingerprint settings in GNOME Settings.

## Install

```bash
url=https://github.com/greedgoddess/kohaku-fprintd-daemon/releases/latest/download
curl -LO $url/kohaku-fprintd.tar.gz -LO $url/kohaku-fprintd.tar.gz.sha256
sha256sum -c kohaku-fprintd.tar.gz.sha256
tar -xzf kohaku-fprintd.tar.gz && cd kohaku-fprintd-*/
sudo ./install.sh                  # sudo ./install.sh --check only checks the requirements
```

Enable fingerprint in PAM if the installer reports it's off, then enrol a finger and log out and back in once:

```bash
sudo authselect enable-feature with-fingerprint && sudo authselect apply-changes
fprintd-enroll && fprintd-verify
```

To uninstall, run `sudo ./install.sh --uninstall`; add `--purge` to also delete the enrolled fingers. Uninstalling restores the stock `fprintd` to its previous state.

## Troubleshooting

- **Logs:** `journalctl -u cros-fprintd -b`
- **Reader dead after suspend, or a failed requirement:** if `cat /sys/power/mem_sleep` shows `[deep]`, enable S0ix in the firmware setup, power off fully, and confirm with `sudo ./install.sh --check`.
- **No fingerprint on the lock screen:** `gsettings get org.gnome.login-screen enable-fingerprint-authentication` must print `true`. Log out and back in once.
- **A USB reader stopped working:** that's expected while this is installed. Uninstall to use it again.

## Security

- **Matching happens on the chip.** Templates leave it only encrypted, and they're stored root-only in `/var/lib/cros-fprintd`. Root can read them.
- **Match results from the chip are trusted as they are,** without ChromeOS's signed matches.
- **Lockout:** after 5 failed matches in a row, fingerprint is locked for 10 minutes.
- **Access rule (no polkit):** callers act only for their own user, unless they run as root.
- **Sandboxed service:** no network, no capabilities, `/dev/cros_fp` as the only device, a read-only system, restricted system calls, and no writable-and-executable memory. `systemd-analyze security` rates it 1.1.
- **Careful file handling:** the seed and templates must be private regular files (no symlinks). They're size-limited and written atomically. A running operation can't restore fingers that were deleted meanwhile.

## Development

- **How it works:**
  - Once per boot, the chip receives a random seed, which is stored root-only.
  - Each user gets an ID, HMAC-SHA256(seed, username), which is set as the chip's context before each operation. The user's templates are then loaded.
  - Enrolment and matching run on the chip and report through events.
  - Templates that the chip updated are saved after matching.
- **Tests:** `tests/run-fake-tests.sh` uses a simulated chip, a private D-Bus and stubbed systemd, so it needs no hardware and no root.
- **Tools:**
  - `tools/fpprobe`: low-level chip probes.
  - `tools/monitor`: a log of reader availability and standby battery drain.
- **Debug logging:**

  ```bash
  sudo mkdir -p /etc/systemd/system/cros-fprintd.service.d
  printf '[Service]\nExecStart=\nExecStart=/usr/bin/python3 -I /usr/local/libexec/cros-fprintd -v\n' \
    | sudo tee /etc/systemd/system/cros-fprintd.service.d/debug.conf
  sudo systemctl daemon-reload && sudo systemctl restart cros-fprintd
  ```

- **Limitations:**
  - At most 5 fingers.
  - GNOME shows 12 enrolment stages; about 10-11 touches are needed.
  - Matching slows down slightly as templates are updated. Re-enrol if it becomes noticeable.
- **Releasing:**

  ```bash
  git tag -s vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z && scripts/make-release.sh vX.Y.Z \
    && gh release create vX.Y.Z dist/kohaku-fprintd.tar.gz dist/kohaku-fprintd.tar.gz.sha256 \
         --title "vX.Y.Z (experimental)" --notes-file release-notes.md
  ```

  The script verifies the tag's signature and scans for secrets. It then builds a reproducible tarball with only the user files.
- **Tested hardware:** the `dartmonkey` chip (RW 2.0.28102) with an FPC sensor. The protocol follows the ChromiumOS EC headers (`ec_commands.h`).

## License

[MIT](LICENSE). The EC command numbers and structure layouts are interface definitions from the ChromiumOS EC headers and the Linux kernel.
