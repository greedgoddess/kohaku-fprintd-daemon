# Suspend on Kohaku

The reader survives suspend only with **s2idle reaching S0ix**. That needs:

- MrChromebox firmware **2609.3 or newer**. 2503.0 didn't advertise S0ix, so Linux fell back to S3.
- The **S0ix** option enabled in the firmware setup (press ESC at boot). Firmware updates reset it.

With both in place, Linux uses s2idle by default, and the laptop stays in S0ix for practically the whole suspend (33.8 s of a 34 s test). The reader works after waking.

**Deep sleep (S3) is unsupported.** On S3 resume, the firmware leaves the fingerprint chip powered off, which upstream coreboot documents as a known limitation for Kohaku. The reader then stays silent until a full power-off.

Check your setup with:

```bash
cat /sys/power/mem_sleep        # should show [s2idle]; [deep] means the S0ix option is off
sudo ./install.sh --check
```

For standby battery drain, see [tools/monitor](../tools/monitor/README.md).
