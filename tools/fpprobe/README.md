# fpprobe

Small C programs that talk to the fingerprint chip through `/dev/cros_fp` (libc only). They were used to work out the protocol, and they're handy for checking whether the chip is alive:

```bash
make && sudo ./fpprobe7      # read-only: answering? limits, command versions, template state
```

Stop the daemon first (`sudo systemctl stop cros-fprintd`) for anything that changes state.

| Program | Changes state? | Does |
|---|---|---|
| `fpprobe`, `fpprobe2`, `fpprobe7` | no | versions, sensor info, mode, encryption status, limits |
| `fpprobe3` | **yes**, until reboot | sets a seed (`./seed.bin`) and a test user context |
| `fpprobe4`, `fpprobe5` | **yes** | one enrolment capture / a full enrolment |
| `fpprobe6` | **yes** | a match against the chip's template |
| `fpprobe8`, `fpprobe9` | dirty flag / **yes** | save template 0 to `./template0.bin` / load it back |

Notes:

- **The chip accepts one seed per boot.** After `fpprobe3`, reboot before using the daemon.
- **`seed.bin` and `template0.bin` are secrets.** Delete them when you're done.
