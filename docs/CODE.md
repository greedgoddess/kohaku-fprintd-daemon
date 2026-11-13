# Code map

Important blocks in this project's code carry a tag comment, `[doc:<id>]`, directly above them.
This page explains each one; link to an entry as `docs/CODE.md#<id>`, and search the code for `[doc:<id>]` to find it.
`tests/test_doc_tags.sh` checks that tags and entries match.

## Daemon ([`cros-fprintd`](../cros-fprintd))

| ID | What and why |
|---|---|
| <a id="dmn-ioctl"></a>`dmn-ioctl` | The kernel's `/dev/cros_fp` ioctl numbers: command transfer and event mask. |
| <a id="dmn-commands"></a>`dmn-commands` | Fingerprint command numbers used by the daemon. |
| <a id="dmn-modes"></a>`dmn-modes` | Chip modes (idle, enrol, match) and the event bits for enrol and match results. |
| <a id="dmn-limits"></a>`dmn-limits` | Protocol constants and sanity limits: seed version, chunk size, template size and count. |
| <a id="dmn-lockout-policy"></a>`dmn-lockout-policy` | Lockout policy: 5 consecutive failures lock fingerprint for 10 minutes. |
| <a id="dmn-dbus-names"></a>`dmn-dbus-names` | D-Bus names and paths, compatible with fprintd; tests switch the bus type. |
| <a id="dmn-introspection"></a>`dmn-introspection` | The subset of the fprintd D-Bus interface the daemon provides. |
| <a id="dmn-mcu-open"></a>`dmn-mcu-open` | Opens `/dev/cros_fp` and selects fingerprint events only. |
| <a id="dmn-mcu-xfer"></a>`dmn-mcu-xfer` | One command round trip through the kernel; `_ok` turns a chip error into `McuError`. |
| <a id="dmn-seed"></a>`dmn-seed` | Sets the seed once per boot; a seed already set by someone else is only accepted for an existing seed file. |
| <a id="dmn-context"></a>`dmn-context` | Sets the per-user context (asynchronous v1 command); this also clears the chip's templates. |
| <a id="dmn-info"></a>`dmn-info` | Reads template size, count and dirty flags, and rejects implausible replies. |
| <a id="dmn-transfer"></a>`dmn-transfer` | Template upload and download in 512-byte chunks, with the commit flag on the last upload chunk. |
| <a id="dmn-mode-events"></a>`dmn-mode-events` | Sets the chip mode and reads fingerprint events from the device. |
| <a id="dmn-atomic-write"></a>`dmn-atomic-write` | Write via an unpredictable temporary file, fsync and atomic rename. |
| <a id="dmn-private-files"></a>`dmn-private-files` | Private file and directory checks: regular file, owner, no group/other access, no symlinks, size limit. |
| <a id="dmn-store"></a>`dmn-store` | State directory and seed: creates a random seed once, refuses an unsafe one. |
| <a id="dmn-userid"></a>`dmn-userid` | Per-user chip context: HMAC-SHA256(seed, user name). |
| <a id="dmn-fingers-json"></a>`dmn-fingers-json` | Reads and validates the finger list; logs unknown, duplicate and missing entries. |
| <a id="dmn-generation"></a>`dmn-generation` | Saves only if no deletion happened since the operation started; deletion bumps the generation. |
| <a id="dmn-lockout"></a>`dmn-lockout` | In-memory count of consecutive failed matches per user. |
| <a id="dmn-session"></a>`dmn-session` | One running verify or enrol: worker thread, stop request, pending stop replies. |
| <a id="dmn-match-result"></a>`dmn-match-result` | Final match decision on the main loop, serialized with deletions. |
| <a id="dmn-access"></a>`dmn-access` | Access rule: callers act for their own user, root for anyone. |
| <a id="dmn-claim"></a>`dmn-claim` | Claims the device for one client; refused while a previous worker is still finishing. |
| <a id="dmn-release"></a>`dmn-release` | Drops the claim; a running worker is stopped and keeps the device busy until it ends. |
| <a id="dmn-worker"></a>`dmn-worker` | Starts a worker thread and clears the session when it has finished. |
| <a id="dmn-prepare"></a>`dmn-prepare` | Seed, user context and template upload before each operation. |
| <a id="dmn-save-dirty"></a>`dmn-save-dirty` | Saves templates the chip updated during matching. |
| <a id="dmn-verify"></a>`dmn-verify` | Verification: arms match mode and turns chip events into fprintd results. |
| <a id="dmn-index-check"></a>`dmn-index-check` | A match only counts for a template index that was actually loaded. |
| <a id="dmn-enroll"></a>`dmn-enroll` | Enrolment: captures until the chip reports 100 %, then downloads and saves the template. |
| <a id="dmn-client-gone"></a>`dmn-client-gone` | Releases the device when the claiming client disconnects. |
| <a id="dmn-dispatch"></a>`dmn-dispatch` | D-Bus method dispatch and error mapping; internal errors are logged, callers get a generic message. |
| <a id="dmn-main"></a>`dmn-main` | Command line, startup and owning the bus name. |

## Installer ([`install.sh`](../install.sh))

| ID | What and why |
|---|---|
| <a id="ins-config"></a>`ins-config` | Minimum firmware and the test-only path prefixes (`FPRINTD_CHECK_ROOT`, `FPRINTD_DESTDIR`). |
| <a id="ins-options"></a>`ins-options` | Reads `--allow-untested-board`; the remaining arguments select install, `--check` or `--uninstall`. |
| <a id="ins-board"></a>`ins-board` | Board check: Google Kohaku passes; other boards fail unless `--allow-untested-board` turns it into a warning. |
| <a id="ins-checks"></a>`ins-checks` | Requirement checks: chip, firmware version, FADT S0ix flag, LPS0 device, default sleep mode. |
| <a id="ins-s0ix-test"></a>`ins-s0ix-test` | Proves S0ix works: residency since boot, or a 20-second test suspend. |
| <a id="ins-readers"></a>`ins-readers` | Finds connected readers the stock fprintd supports, using libfprint's hardware database. |
| <a id="ins-fprintd-state"></a>`ins-fprintd-state` | Which stock fprintd states can be restored, and how each is restored. |
| <a id="ins-uninstall"></a>`ins-uninstall` | Removes only the project's files and restores the recorded fprintd state. |
| <a id="ins-reader-question"></a>`ins-reader-question` | Asks before masking fprintd when one of its readers is connected. |
| <a id="ins-prev-state"></a>`ins-prev-state` | Records fprintd's state and refuses states that can't be restored exactly. |
| <a id="ins-rollback"></a>`ins-rollback` | Restores files and fprintd's state if any later step fails. |
| <a id="ins-install"></a>`ins-install` | Installs the daemon, unit and udev rule, then masks the stock fprintd. |
| <a id="ins-record"></a>`ins-record` | Writes the state record atomically while rollback is still possible. |

## Service unit ([`systemd/cros-fprintd.service`](../systemd/cros-fprintd.service))

| ID | What and why |
|---|---|
| <a id="svc-start"></a>`svc-start` | D-Bus activated start in Python's isolated mode. |
| <a id="svc-state"></a>`svc-state` | Private state directory and umask. |
| <a id="svc-sandbox"></a>`svc-sandbox` | Sandbox: filesystem, kernel, devices, network, privileges, memory and system calls. |

## udev rule ([`udev/70-cros-fprintd.rules`](../udev/70-cros-fprintd.rules))

| ID | What and why |
|---|---|
| <a id="udv-start"></a>`udv-start` | Starts the service when `/dev/cros_fp` appears, even after boot. |

## Release script ([`scripts/make-release.sh`](../scripts/make-release.sh))

| ID | What and why |
|---|---|
| <a id="rel-signature"></a>`rel-signature` | Verifies the tag's signature; an unsigned tag only warns. |
| <a id="rel-secrets"></a>`rel-secrets` | Refuses to build if private files or secrets are tracked at the tag. |
| <a id="rel-archive"></a>`rel-archive` | Packs only the user files, with fixed order, owners and timestamps. |

## Monitor ([`tools/monitor/cros-fprintd-monitor`](../tools/monitor/cros-fprintd-monitor))

| ID | What and why |
|---|---|
| <a id="mon-log"></a>`mon-log` | Appends one timeline line and rotates the log at 2 MB. |
| <a id="mon-probe-chip"></a>`mon-probe-chip` | Read-only chip checks: hello, seed bit, mode. |
| <a id="mon-battery"></a>`mon-battery` | Battery energy and charger state from sysfs. |
| <a id="mon-snapshot"></a>`mon-snapshot` | Combines all probes into one state and the `avail=` verdict. |
| <a id="mon-inhibit"></a>`mon-inhibit` | Short logind delay lock, so readings are taken before the system sleeps. |
| <a id="mon-sleep"></a>`mon-sleep` | Per-suspend summary: duration, S0ix share, battery used, standby estimate. |
| <a id="mon-journal"></a>`mon-journal` | Copies relevant journal lines into the timeline. |
| <a id="mon-report"></a>`mon-report` | Average standby drain over all logged sleeps on battery. |

## crfpmoc test tool ([`tools/crfpmoc-test/crfpmoc-test.sh`](../tools/crfpmoc-test/crfpmoc-test.sh))

| ID | What and why |
|---|---|
| <a id="crf-hold"></a>`crf-hold` | Holds cros-fprintd back with a drop-in, since its unit can't be masked. |
| <a id="crf-build"></a>`crf-build` | Fetches merge request !512 and builds libfprint in the home directory. |
| <a id="crf-patch"></a>`crf-patch` | Applies the local reply-size fix for the FP_MODE calls. |
| <a id="crf-run"></a>`crf-run` | Runs the stock fprintd against the test build; refuses if the chip is already seeded. |

## Probes ([`tools/fpprobe/`](../tools/fpprobe/))

| ID | File | Purpose |
|---|---|---|
| <a id="prb-compat"></a>`prb-compat` | [`cros_ec_compat.h`](../tools/fpprobe/cros_ec_compat.h) | Minimal re-declaration of the kernel's command structure and ioctl. |
| <a id="prb-hello"></a>`prb-hello` | [`fpprobe.c`](../tools/fpprobe/fpprobe.c) | Read-only: is the chip answering, and what is it. |
| <a id="prb-state"></a>`prb-state` | [`fpprobe2.c`](../tools/fpprobe/fpprobe2.c) | Read-only: mode, encryption status, sensor details. |
| <a id="prb-seed"></a>`prb-seed` | [`fpprobe3.c`](../tools/fpprobe/fpprobe3.c) | Sets a seed and a test user context. |
| <a id="prb-capture"></a>`prb-capture` | [`fpprobe4.c`](../tools/fpprobe/fpprobe4.c) | One enrolment capture. |
| <a id="prb-enroll"></a>`prb-enroll` | [`fpprobe5.c`](../tools/fpprobe/fpprobe5.c) | A full enrolment. |
| <a id="prb-match"></a>`prb-match` | [`fpprobe6.c`](../tools/fpprobe/fpprobe6.c) | A match against the chip's template. |
| <a id="prb-limits"></a>`prb-limits` | [`fpprobe7.c`](../tools/fpprobe/fpprobe7.c) | Read-only: transfer limits, command versions, template state. |
| <a id="prb-save"></a>`prb-save` | [`fpprobe8.c`](../tools/fpprobe/fpprobe8.c) | Downloads template 0 to a file. |
| <a id="prb-load"></a>`prb-load` | [`fpprobe9.c`](../tools/fpprobe/fpprobe9.c) | Uploads a saved template again. |

## Tests ([`tests/`](../tests/))

| ID | File | Covers |
|---|---|---|
| <a id="tst-runner"></a>`tst-runner` | [`run-fake-tests.sh`](../tests/run-fake-tests.sh) | Runs all suites; waits for each daemon on the bus and cleans up. |
| <a id="tst-fake-chip"></a>`tst-fake-chip` | [`fake_daemon.py`](../tests/fake_daemon.py) | Loads the real daemon with a simulated chip on the session bus. |
| <a id="tst-helpers"></a>`tst-helpers` | [`dbus_helpers.py`](../tests/dbus_helpers.py) | Shared D-Bus client, signal collection and checks. |
| <a id="tst-store"></a>`tst-store` | [`test_store.py`](../tests/test_store.py) | Storage: private files, size limits, JSON validation, deletion generation. |
| <a id="tst-match-ordering"></a>`tst-match-ordering` | [`test_match_ordering.py`](../tests/test_match_ordering.py) | A deletion before the queued match result turns it into no match. |
| <a id="tst-api"></a>`tst-api` | [`test_fake_dbus.py`](../tests/test_fake_dbus.py) | Main D-Bus API suite: claim, enrol, verify, persistence, delete. |
| <a id="tst-lockout"></a>`tst-lockout` | [`test_lockout.py`](../tests/test_lockout.py) | Five failures lock verification. |
| <a id="tst-lockout-reset"></a>`tst-lockout-reset` | [`test_lockout_reset.py`](../tests/test_lockout_reset.py) | A match resets the count; the lockout expires. |
| <a id="tst-bad-index"></a>`tst-bad-index` | [`test_bad_index.py`](../tests/test_bad_index.py) | A match for an invalid template index is rejected. |
| <a id="tst-worker"></a>`tst-worker` | [`test_concurrency.py`](../tests/test_concurrency.py) | A released session keeps the device busy until its worker ends. |
| <a id="tst-delete-race"></a>`tst-delete-race` | [`test_delete_race.py`](../tests/test_delete_race.py) | Deleting during verify: no match, nothing recreated. |
| <a id="tst-doc-tags"></a>`tst-doc-tags` | [`test_doc_tags.sh`](../tests/test_doc_tags.sh) | Every code tag has an entry in this file, and every entry a tag. |
| <a id="tst-installer"></a>`tst-installer` | [`test_installer.sh`](../tests/test_installer.sh) | Installer and uninstaller in a temporary root with stubbed systemctl. |
