# Field test

**Source:** the [monitor](../tools/monitor/README.md) log from a week of daily use on the owner's laptop. The log itself isn't published. This test is the basis for the alpha status.

| | |
|---|---|
| Period | 7-13 November 2026 |
| Hardware | Samsung Galaxy Chromebook (Kohaku), MrChromebox 2609.3 with S0ix enabled |
| System | Fedora 45, GNOME Shell 51, cros-fprintd v0.9.x |

## Result

**No unexpected behaviour.** Enrolment, `sudo`, the lock screen and fingerprint after suspend worked throughout. The service never restarted, and no daemon errors or failed authentications were logged.

## Availability

Each time the monitor reported the reader as unavailable, the cause is known:

- **One day in deep sleep (S3):** the S0ix option was off in the firmware setup after a firmware update, and was fixed the same day.
- **About ten minutes without cros-fprintd:** deliberate, during the [crfpmoc test](CRFPMOC.md).
- **A few single missed replies from the chip,** over about a day. Each hit only one of the monitor's own probes while the chip was idle, and the next probe a minute later found it answering normally. None occurred during a fingerprint operation, and none after the first two days. The likely cause is an idle chip occasionally not waking fast enough for the kernel's short reply deadline. A fingerprint request hitting such a moment would fall back to the password once; that never noticeably happened.

## Standby

| | |
|---|---|
| Time in S0ix while asleep | 100 % |
| Average standby power | about 220 mW (0.5 % battery per hour) |
| Standby from a full charge | about 8.6 days |

These figures are averages over suspends on battery of at least 10 minutes. Short suspends use more on average, because entering and leaving sleep weighs more over a short time.
