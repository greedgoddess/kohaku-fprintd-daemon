# libfprint's crfpmoc driver on Kohaku

[crfpmoc](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/512) is a proposed libfprint driver for ChromeOS fingerprint chips. In the long run it's the better approach: it's maintained upstream and works with the stock `fprintd`. We tested it on Kohaku to see whether it could replace this project.

**Result: not yet.** The driver doesn't get past the start of enrolment on Kohaku's firmware.

## What was tested

| | |
|---|---|
| Driver | merge request !512 at `56442591` (2026-07-24, "crfpmoc: Randomize the context and seed values") |
| Hardware | Samsung Galaxy Chromebook (Kohaku), `dartmonkey` firmware RW 2.0.28102, FPC1145 sensor |
| System | Fedora 45, stock `fprintd` 1.94.5 run by hand against the built library; nothing installed system-wide |

## Results

| Step | cros-fprintd | crfpmoc |
|---|---|---|
| Build | — | ⚠️ only together with another udev driver |
| Open the reader | ✅ | ✅ reads the same chip parameters |
| Enrol | ✅ | ❌ fails before the first touch |
| With a local fix applied | — | ❌ fprintd crashes |

The later checks (verify, saving updated templates, reboot, suspend, `sudo`, lock screen) weren't reachable.

## Findings

**1. Building only crfpmoc fails.** With `-Ddrivers=crfpmoc`, the build stops at `#error "crfpmoc requires udev"`. libfprint enables udev support only when a driver on its udev list is part of the build. Building it together with `elanspi` works.

**2. Mode commands expect no reply, but this firmware sends one.** Enrolment fails immediately: the driver's clear-storage step reports an ioctl error ("message too long"), and the kernel reports that the chip sent 4 bytes where none were expected. On this firmware, the FP_MODE command always returns the current mode (4 bytes). cros-fprintd always accepts that reply. Four of crfpmoc's ten FP_MODE calls ask for a 0-byte reply. Asking for the 4-byte reply there, as the other six calls do, fixes this step (`crfpmoc-test.sh patch` applies that locally).

**3. Then a read callback runs on a freed state machine, and fprintd crashes.** The read callback gets its state machine from the event source, without holding a reference. When the state machine was freed, the source wasn't removed, because its recorded ID was already 0. The next chip event then ran the callback on freed memory. GLib reported invalid device, stream and object pointers, and fprintd ended with a segmentation fault.

## Repeating the test

[`tools/crfpmoc-test/crfpmoc-test.sh`](../tools/crfpmoc-test/crfpmoc-test.sh) builds the driver in `~/src/crfpmoc-test` and runs the stock `fprintd` against it. cros-fprintd is held back for the test and restored afterwards. The chip accepts one seed per boot, so the test needs its own boot:

```bash
tools/crfpmoc-test/crfpmoc-test.sh build    # optionally followed by: ... patch
tools/crfpmoc-test/crfpmoc-test.sh hold && sudo reboot
tools/crfpmoc-test/crfpmoc-test.sh run      # terminal 1; enrol and verify in terminal 2
tools/crfpmoc-test/crfpmoc-test.sh restore && sudo reboot
```

`crfpmoc-test.sh state` shows the chip's seed and template state, the prints fprintd stored, and any SELinux denials.
