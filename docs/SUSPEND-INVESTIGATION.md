# Kohaku: fingerprint MCU dead after S3 resume, investigation notes

> **Resolved for s2idle with MrChromebox-2609.3.** After updating from 2503.0, the FADT advertises S0ix (`Low Power S0 Idle (V5) : 1`) and Linux defaults to s2idle. In a 34-second test, `slp_s0_residency_usec` rose by 33.8 seconds (S0ix for practically the whole suspend). No `EC detected sleep transition timeout` appeared, and the FPMCU answered normally afterwards. A longer suspend was fine as well. Possibly relevant release notes: S0ix EC/CREC sleep-notification hooks (2606.0) and an infinite EC host-sleep timeout by default (2609.0). Note that 2609.3 has an **S0ix option in its setup menu**. It was off on the test machine after the update reset all firmware settings: with it off, the FADT flag is cleared, Linux falls back to S3, and the original problem returns. Deep sleep (S3) hasn't been re-tested on 2609.3 and is **unsupported** by this project. The installer refuses to install unless s2idle with working S0ix is in use. The notes below describe the original problem on 2503.0.

**Summary.** On a Samsung Galaxy Chromebook (Kohaku) with MrChromebox UEFI firmware and Fedora, the fingerprint MCU (FPMCU) works from a cold boot. Through `/dev/cros_fp`, enrolment, matching and template save/restore all work with the daemon in this repository. After a **deep (S3) suspend**, the FPMCU never answers on SPI again until a **full power-off**. Toggling its reset and power-enable GPIOs from Linux doesn't bring it back, although the same toggles do restart it cleanly while it's healthy. With **s2idle** the FPMCU survives, but the machine wakes by itself after about 10 seconds without reaching S0ix.

**Update:** upstream coreboot already documents that S3 resume doesn't work for the FPMCU on Kohaku (see [Firmware behaviour on S3 resume](#firmware-behaviour-on-s3-resume)). After S3, the firmware leaves the FPMCU's power and reset GPIOs low. Restoring them from Linux, even with a 15-second power-off and a re-initialised SPI controller, does not bring the FPMCU back.

Corrections and ideas are very welcome, especially from anyone with the Hatch/Kohaku schematic or knowledge of the MrChromebox S3 resume path for this board.

## Environment

| | |
|---|---|
| Device | Samsung Galaxy Chromebook, board Kohaku (Hatch family, Comet Lake) |
| Firmware | MrChromebox UEFI full ROM, `MrChromebox-2503.0` (dmesg: `DMI: Google Kohaku/Kohaku, BIOS MrChromebox-2503.0 04/27/2025`) |
| OS | Fedora 45, kernel `7.2.15-300.fc45.x86_64` |
| FPMCU | `dartmonkey`, RO `dartmonkey_v2.0.2887-311310808`, RW `dartmonkey_v2.0.28102-64c3d5971`, running RW |
| Sensor | FPC (vendor id "FPC "), model `0x140c`, 56×192, template 47,616 bytes, max 5 templates, format version 4 |
| Transport | `cros-ec-spi spi-PRP0001:02`, EC protocol v3, max request/response 544 bytes |
| Host GPIO | `gpiochip0 [INT34BB:00]` (312 lines), plus `cros-ec-gpio` chips for the EC and the FPMCU |

## Symptom

After any `PM: suspend entry (deep)` / `PM: suspend exit`, every FPMCU command fails:

```
cros-ec-spi spi-PRP0001:02: EC failed to respond in time
```

This is reproducible: it happened in every controlled test (4 deep suspends) and in an earlier, unplanned episode. It persists for as long as I waited (over 20 minutes), and only a full power-off fixes it.

I also saw two spontaneous short deep suspends of 1-2 seconds each (`suspend entry (deep)` → `suspend exit`). Other owners have reported the machine waking immediately on lid close.

## What I tried after a failed S3 resume (none helped)

1. **Rebind the driver:** `echo spi-PRP0001:02 > /sys/bus/spi/drivers/cros-ec-spi/unbind`, then `bind`. The probe fails:
   ```
   cros-ec-spi spi-PRP0001:02: Failed to continue RWSIG: -110
   cros-ec-spi spi-PRP0001:02: Cannot identify the EC: error -110
   cros-ec-spi spi-PRP0001:02: probe with driver cros-ec-spi failed with error -110
   ```
2. **Unbind before suspend, bind after resume,** so the kernel never sends the FPMCU any suspend or resume handshake. The bind after resume fails the same way.
3. **Pulse the FPMCU reset:** `gpioset` on `gpiochip0` line 12 (GPP_A12, see below), low for 1 s then high. The FPMCU is still silent after 3-10 s.
4. **Power-cycle the FPMCU**, mimicking coreboot's ramstage sequence: reset low and power-enable low for 1 s, then power on, then release reset. The FPMCU is still silent after 4 s and 10 s, and a subsequent bind still fails as in (1).

## GPIO mapping (verified on a healthy FPMCU)

From coreboot's Hatch sources and ChromeOS's `flash_fp_mcu`:

- `GPP_A12` = `FPMCU_RST_ODL`
- `GPP_A22` = FPMCU `BOOT0` (never touched)
- `GPP_C11` = `EN_FP_RAILS` / `PCH_FP_PWR_EN`

On this kernel's numbering:

| Pad | `gpiochip0` line | How verified |
|---|---|---|
| GPP_A12 (reset) | 12 | With the FPMCU healthy and the seed set (`FP_ENC_STATUS` = 1), driving line 12 low for 1 s → FPMCU rebooted (seed bit cleared) and answered normally within 5 s |
| GPP_C11 (power) | 267 | Same test with line 267 low for 1 s → FPMCU rebooted (seed bit cleared) and answered within 5 s |
| GPP_C14 (`BT_DISABLE_L`) | 270 | Only line held by a driver (`consumer="reset"`, active-low output), consistent with group C starting at line 256 |

`gpioinfo` showed lines 12, 267 and 268 as outputs, and 11, 13, 14, 22 and 266 as inputs.

**Conclusion so far:** a reset or power cycle restarts a healthy FPMCU fine, but neither helps after S3. Whatever S3 breaks seems to be outside the FPMCU's own reset and power domain, and outside the Linux driver.

## Firmware behaviour on S3 resume

The coreboot change that introduced the current FPMCU power/reset handling for the Hatch family, [CL 37459 "hatch: Fix FPMCU pwr/rst gpio handling"](https://review.coreboot.org/c/coreboot/+/37459), describes the sequence as:

1. no GPIO control in bootblock,
2. disable power and assert reset in ramstage GPIO configuration,
3. power on and then deassert reset at the end of ramstage,
4. disable power and assert reset when entering S5.

Its commit message also states that S3 resume will still not work properly, because step 2 forces the FPMCU's power off. In the list of scenarios validated on a Kohaku, "entering and leaving S3" is marked as not working, while S0ix isn't. ChromeOS presumably avoids this by using S0ix.

What the pins show on this machine (`gpiochip0`, lines verified as above; `gpioget --as-is` reads without changing direction):

| Line | Pad | Fresh boot | After S3 resume |
|---|---|---|---|
| 12 | GPP_A12, `FPMCU_RST_ODL` | `active` (reset released) | `inactive` (reset asserted) |
| 267 | GPP_C11, `EN_FP_RAILS` | `active` (powered) | `inactive` (unpowered) |
| 22 | GPP_A22, FPMCU BOOT0 | | `inactive` (normal boot) |

So the firmware's S3 path leaves the FPMCU unpowered and in reset, consistent with step 2 running without step 3.

Recovery attempts after S3, all of which failed (the FPMCU never answered, and a fresh `cros-ec-spi` probe ended with `Failed to continue RWSIG: -110` and `cannot register EC`):

- **Restore power and reset:** the pads are not locked. `gpioset` changed lines 267 and 12 to `active`, and they read back as such.
- **Clean power-up:** with BOOT0 held low, reset held, power off for 1 s and then for 15 s, power on, release reset.
- **Fresh SPI controller:** unbind and rebind of the LPSS SPI controller (`0000:00:1e.3`, driver `intel-lpss`) after the power-up. The re-probe of the controller printed a kernel warning trace (`pxa2xx_spi_probe` → `intel_lpss_probe`).
- **No visible GPIO changes:** `gpioinfo --chip gpiochip0` before and after S3 is identical. Directions, flags and consumers are the same; output values and pin-mux modes aren't shown by `gpioinfo`.

The same power and reset toggles restart a healthy FPMCU within 5 seconds. So after S3 something else is missing that a GPIO power-up plus a controller re-init doesn't restore, most likely on the host side of the SPI link (for example the GSPI1 pad mux), or a sleep input the FPMCU watches.

## Other observations after a failed S3 resume

- **Main EC sleep lines:** `gpioget` shows `"EC:SLP_S0_L"=active "EC:SLP_S3_L"=active "EC:SLP_S4_L"=active`, which I read as the EC seeing the host fully awake.
- **Wake IRQ:** `/sys/power/pm_wakeup_irq` reported no data after the deep resume.
- **Interrupts:** the FPMCU's interrupt is `47 ... chromeos-ec`. The SPI controllers (`pxa2xx-spi.5/.6`) and the TPM (`cr50_spi`) keep counting.
- **Debug files:** `/sys/kernel/debug/cros_fp` and `/sys/kernel/debug/cros_ec` don't exist on Fedora's kernel, and there's no pinctrl debugfs. So I couldn't read the FPMCU console log or the pad configuration directly.
- **FPMCU GPIOs:** while it's alive, the FPMCU exposes its own GPIOs via `cros-ec-gpio`, including `EC:SLP_L`, `EC:SLP_ALT_L`, `EC:FPS_INT`, `EC:FP_SPI_SEL` and `EC:FP_RST_ODL`. After S3 these can't be read, because the FPMCU doesn't answer.

## ACPI description of the FPMCU

From `acpidump`, the SSDT:

```
Scope (\_SB.PCI0.SPI1)
    Device (CRFP)
        _HID "PRP0001", _UID 1, _STA 0x0B
        _CRS: SpiSerialBusV2 (CS 1, PolarityLow, FourWire, 8 bit, 1 MHz, mode 0, "\_SB.PCI0.SPI1")
              Interrupt (Level, ActiveLow, SharedAndWake) { 0x2F }
        _S0W 3
        _PRW { 0x17, 3 }
        _DSD { "compatible" = "google,cros-ec-spi" }
```

There's no `_PR0`, `_PS0` or `_PS3`, and no GPIO resources, so the OS has no ACPI-described way to power or reset the FPMCU. There's also no `google,cros-ec-spi-pre-delay` or `google,cros-ec-spi-msg-delay`.

`/proc/acpi/wakeup` lists: `LID0 S4 enabled`, `CREC S5 disabled`, `H020 S3 enabled (SYNA0000 touchpad)`, `CRFP S3 enabled`, `XHCI S4 enabled`, `CNVW S3 disabled`.

## s2idle (on 2503.0)

With `echo s2idle > /sys/power/mem_sleep`:

- **The FPMCU survives:** `fprintd-verify` matches after resume.
- **The machine resumes on its own after about 10 s:** `PM: suspend entry (s2idle)` at 74.59 → `suspend exit` at 85.28, and again 167.56 → 178.03.
- **S0ix is never reached:** `/sys/kernel/debug/pmc_core/slp_s0_residency_usec` was 0 before and after.
- **The wake came through ACPI:** `pm_wakeup_irq` was `9` (`acpi`). None of the `/sys/firmware/acpi/interrupts/gpe*` counters changed across the suspend.

Unverified hypothesis: the EC's sleep-failure watchdog wakes the host because SLP_S0 is never asserted (no S0ix). So s2idle isn't currently usable on this setup.

## Hypotheses

1. **Firmware S3 path (confirmed in part):** the resume path powers the FPMCU off and holds it in reset (coreboot CL 37459, and the pin readings above), and it never powers it back up.
2. **Host-side SPI path:** on top of that, something on the host side of the FPMCU's SPI link (most likely the GSPI1 pad configuration: CS on GPP_A11 in native mode, plus clock and data pins) isn't restored by the S3 resume path. Re-powering the FPMCU and re-initialising the SPI controller from Linux don't fix this, and Linux can't safely re-mux those pads itself.
3. **Sleep input stuck:** a sleep signal the FPMCU watches (`SLP_L` / `SLP_ALT_L`) stays asserted after S3 resume, so even a freshly powered FPMCU goes straight back to low power. The main EC reports `SLP_S0_L`/`SLP_S3_L`/`SLP_S4_L` as `active` after resume, which argues against this, but the FPMCU's own inputs can't be read while it's silent.

The FPMCU surviving s2idle and dying in S3, and coreboot documenting S3 as broken for it on Kohaku, both point at the firmware's S3 path rather than the FPMCU firmware or the Linux driver.

## Questions

- Could the MrChromebox build re-run the FPMCU power-up (step 3: `GPP_C11` high, about 1 ms delay, `GPP_A12` high) on S3 resume? Does it restore the GSPI1 pads on resume?
- Does the FPMCU work after S3 resume on Kohaku with stock ChromeOS firmware running Linux (for example via RW_LEGACY)?
- Is anyone getting S0ix on Kohaku under Linux with MrChromebox firmware? With S0ix, the FPMCU would presumably not be powered down at all.

## Reproducing

The daemon (`cros-fprintd`) and the probe tools (`tools/fpprobe`) in this repository are what I used. A minimal reproduction:

```bash
cd tools/fpprobe && make
./fpprobe7 | head -2                 # alive: "protocol info: ioctl=12 ec_result=0"
systemctl suspend                    # deep (S3); wake it
./fpprobe7 | head -2                 # dead: "protocol info: ioctl=-1 ..."
sudo dmesg | grep cros-ec-spi | tail # "EC failed to respond in time"
```
