# kohaku-fprintd-daemon

[![Latest release](https://img.shields.io/github/v/release/greedgoddess/kohaku-fprintd-daemon?label=release)](https://github.com/greedgoddess/kohaku-fprintd-daemon/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![Status: experimental](https://img.shields.io/badge/status-experimental-orange)

**Fingerprint unlock for the Samsung Galaxy Chromebook (Kohaku) on Fedora.**
`sudo`, the GNOME lock screen and the `fprintd-*` tools use the built-in reader.

The daemon, `cros-fprintd`, provides the standard `fprintd` D-Bus interface and talks to the ChromeOS fingerprint chip through `/dev/cros_fp`.

> [!WARNING]
> - **Experimental and pre-1.0.** It was built for and tested on one laptop: Kohaku, MrChromebox 2609.3, Fedora 45, GNOME Shell 51. It isn't regularly maintained; forks are welcome.
> - **It runs as root and changes your PAM configuration.** Keep a root shell open while you enable fingerprint. Your password always remains a fallback.
> - **Not security-audited.** Treat fingerprint as a convenience, not as your only protection.

> [!NOTE]
> This project was written largely by an AI assistant (Claude, by Anthropic), directed and tested on the hardware by the author. It has had no independent review, so read `install.sh` and `cros-fprintd` before running them as root.

## Requirements

The installer checks these and refuses to install otherwise.

| Requirement | Notes |
|---|---|
| Kohaku with a working reader | `/dev/cros_fp` must exist |
| MrChromebox firmware **2609.3 or newer** | with the **S0ix** option enabled in the firmware setup (ESC at boot); firmware updates reset it |
| s2idle with working S0ix | checked with a 20-second test suspend if needed |

- **Deep sleep (S3) isn't supported:** after it, the reader stays off until a full power-off. See [docs/SUSPEND.md](docs/SUSPEND.md).
- **Other fingerprint readers (such as USB readers) don't work while this is installed,** because the stock `fprintd` gets masked. If one is connected, the installer asks first.

## Status

| Feature | Status |
|---|---|
| Enrol and verify | ✅ |
| `sudo` | ✅ |
| GNOME lock screen | ✅ |
| After suspend | ✅ |
| polkit prompts, GNOME Settings | untested |

## Similar projects

| Project | Approach | On Kohaku |
|---|---|---|
| **This project** | Takes the place of the `fprintd` service with the same D-Bus interface; the stock PAM module, GNOME and tools work unchanged, and nothing needs compiling | ✅ works |
| [libfprint `crfpmoc`](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/512) | A proposed libfprint driver (merge requests !493, !512); the stock `fprintd` keeps running, so other readers keep working | ❌ not yet: enrolment fails, then crashes ([test report](docs/CRFPMOC.md)) |
| [rust-fp](https://github.com/ChocolateLoverRaj/rust-fp) | Its own library, D-Bus service and PAM module, written in Rust | not tested; aimed at KDE Plasma, GNOME isn't supported |

Once the libfprint driver works on Kohaku and ships in Fedora's libfprint, it will be the better long-term choice: it's maintained upstream and doesn't replace `fprintd`.

## Install

```bash
url=https://github.com/greedgoddess/kohaku-fprintd-daemon/releases/latest/download
curl -LO $url/kohaku-fprintd.tar.gz -LO $url/kohaku-fprintd.tar.gz.sha256
sha256sum -c kohaku-fprintd.tar.gz.sha256
tar -xzf kohaku-fprintd.tar.gz && cd kohaku-fprintd-*/
sudo ./install.sh            # or: sudo ./install.sh --check, to only check the requirements
```

Enable fingerprint in PAM if the installer reports it's off. Then enrol a finger, and log out and back in once:

```bash
sudo authselect enable-feature with-fingerprint && sudo authselect apply-changes
fprintd-enroll && fprintd-verify
```

**Uninstall:** `sudo ./install.sh --uninstall`. Add `--purge` to also delete the enrolled fingers. The stock `fprintd` is restored to its previous state.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Reader dead after suspend, or a failed requirement | `cat /sys/power/mem_sleep` shows `[deep]`: enable S0ix in the firmware setup, power off fully, check with `sudo ./install.sh --check` |
| No fingerprint on the lock screen | `gsettings get org.gnome.login-screen enable-fingerprint-authentication` must print `true`; log out and back in once |
| A USB reader stopped working | expected while installed; uninstall to use it again |
| Anything else | `journalctl -u cros-fprintd -b` |

## Security

- **Matching happens on the chip.** Templates leave it only encrypted, and they're stored root-only in `/var/lib/cros-fprintd`. Root can read them.
- **Match results from the chip are trusted as they are,** without ChromeOS's signed matches.
- **Lockout:** after 5 failed matches in a row, fingerprint is locked for 10 minutes.
- **Access rule (no polkit):** callers act only for their own user, unless they run as root.
- **Sandboxed service:** no network, no capabilities, `/dev/cros_fp` as the only device, a read-only system, restricted system calls, and no writable-and-executable memory. `systemd-analyze security` rates it 1.1.
- **Careful file handling:** the seed and templates must be private regular files (no symlinks), are size-limited, and are written atomically. Deleted fingers can't be restored by an operation that was already running.

## Development

### How it works

1. **Seed:** once per boot, the chip receives a random seed, which is stored root-only.
2. **User context:** each user gets an ID, HMAC-SHA256(seed, username). It's set as the chip's context before each operation, and the user's templates are loaded.
3. **On the chip:** enrolment and matching run on the chip and report back through events.
4. **After matching:** templates the chip updated are saved.

Tested with the `dartmonkey` chip (RW 2.0.28102) and an FPC sensor. The protocol follows the ChromiumOS EC headers (`ec_commands.h`).

### Tests and tools

| Path | Purpose |
|---|---|
| `tests/run-fake-tests.sh` | all tests: simulated chip, private D-Bus, stubbed systemd; no hardware or root needed |
| [`tools/fpprobe`](tools/fpprobe/README.md) | low-level chip probes |
| [`tools/monitor`](tools/monitor/README.md) | log of reader availability and standby battery drain |
| [`tools/crfpmoc-test`](docs/CRFPMOC.md#repeating-the-test) | tests libfprint's crfpmoc driver on this hardware |

To turn on debug logging for the installed service:

```bash
sudo mkdir -p /etc/systemd/system/cros-fprintd.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/python3 -I /usr/local/libexec/cros-fprintd -v\n' \
  | sudo tee /etc/systemd/system/cros-fprintd.service.d/debug.conf
sudo systemctl daemon-reload && sudo systemctl restart cros-fprintd
```

### Limitations

- At most 5 fingers.
- GNOME shows 12 enrolment stages; about 10-11 touches are needed.
- Matching slows down slightly as templates are updated. Re-enrol if it becomes noticeable.

### Releasing

```bash
git tag -s vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z && scripts/make-release.sh vX.Y.Z \
  && gh release create vX.Y.Z dist/kohaku-fprintd.tar.gz dist/kohaku-fprintd.tar.gz.sha256 \
       --title "vX.Y.Z (experimental)" --notes-file release-notes.md
```

The script verifies the tag's signature and scans for secrets. It then builds a reproducible tarball with only the user files.

## Documentation

- [docs/CODE.md](docs/CODE.md): code map. Important blocks carry a `[doc:<id>]` tag that's explained there.
- [docs/SUSPEND.md](docs/SUSPEND.md): why suspend needs S0ix, and why deep sleep isn't supported.
- [docs/CRFPMOC.md](docs/CRFPMOC.md): test report for libfprint's crfpmoc driver on Kohaku.

## License

[MIT](LICENSE). The EC command numbers and structure layouts are interface definitions from the ChromiumOS EC headers and the Linux kernel.
