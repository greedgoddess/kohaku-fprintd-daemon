# fpprobe: low-level probes for the ChromeOS fingerprint MCU

Small C programs that talk to the fingerprint MCU through `/dev/cros_fp` with the kernel's `cros_ec` ioctl. They were used to work out the protocol before writing the daemon, and they're handy for checking whether the MCU is alive. They need no libraries beyond libc: `cros_ec_compat.h` defines the two kernel structures they use.

```bash
make
./fpprobe7          # read-only: is the MCU answering? packet sizes, command versions, template state
```

Run them as root, or as a user in the group that owns `/dev/cros_fp` (`plugdev` on the test machine). Stop the daemon first (`sudo systemctl stop cros-fprintd`) for anything that changes state.

| Program | Changes MCU state? | What it does |
|---|---|---|
| `fpprobe` | no | hello, firmware versions, `FP_INFO` (sensor, sizes) |
| `fpprobe2` | no | current mode, stats, encryption status |
| `fpprobe7` | no | protocol limits, supported command versions, template valid/dirty |
| `fpprobe3` | **yes** (until reboot) | creates/loads `./seed.bin`, sets the seed (once per boot) and a fixed test user context |
| `fpprobe4` | **yes** | starts one enroll image capture, then returns to idle |
| `fpprobe5` | **yes** | full enrolment driven by fingerprint events (template stays in MCU RAM) |
| `fpprobe6` | **yes** | matches against the template in the MCU (updates the template) |
| `fpprobe8` | only clears the "dirty" flag | reads template 0 out (encrypted) to `./template0.bin` |
| `fpprobe9` | **yes** | loads `./template0.bin` back into the MCU |

Notes:

- **One seed per boot.** The MCU accepts one seed per boot. If you run `fpprobe3` and later install the daemon in the same boot, pass `seed.bin` to `install.sh`, or reboot first.
- **The test user id is not the daemon's.** `fpprobe3` uses a fixed test user id, so templates saved with `fpprobe8` can't be loaded by the daemon, which derives a different id per user.
- **Treat the files as secrets.** `seed.bin` and `template0.bin` are sensitive. They're written with mode 0600; delete them when you're done.

## Kohaku GPIOs (for reset and power experiments)

On the Samsung Galaxy Chromebook (Kohaku) with this kernel's numbering, the FPMCU's reset is `gpiochip0` line 12 (GPP_A12) and its power enable is line 267 (GPP_C11). Never drive line 22 (GPP_A22, BOOT0). In libgpiod 2, `gpioset` keeps running until stopped, so wrap it in `timeout`:

```bash
sudo timeout 1 gpioset --chip gpiochip0 12=0    # hold reset for 1 s
sudo timeout 1 gpioset --chip gpiochip0 12=1    # release
```

These numbers were verified on one machine only; see `docs/SUSPEND-INVESTIGATION.md`. On other boards they will differ.
