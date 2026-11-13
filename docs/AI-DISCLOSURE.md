# AI disclosure

This project was developed with AI. The human owner decides and tests; AI writes and reviews.

| Role | Who | Responsibilities |
|---|---|---|
| Owner | greedgoddess (human) | Goals and decisions, all tests on the hardware, the field test, publishing and releases |
| Development | Claude (Anthropic), in claude.ai chat | Protocol work through the probe tools, all code, tests, documentation and release tooling |
| External review | ChatGPT (OpenAI) | Independent code reviews; findings were checked against the code and fixed by development |

## What that means for you

- **All hardware findings come from real tests on the owner's laptop,** not from the AI's assumptions.
- **There has been no independent human code review yet.** Read `install.sh` and `cros-fprintd` before running them as root.

## External reviews

| Review | Main findings | Fixed in |
|---|---|---|
| 1 | Invalid match index accepted, worker outliving its session, deletion races, predictable temporary files, seed file permissions, installer rollback, more sandboxing | v0.9.1 |
| 2 | Remaining gaps in deletion handling and file-list validation; missing regression tests | v0.9.3 |
| 3 | New claims while a worker finishes, the stock fprintd's state not preserved, lockout tests | v0.9.3 |
| 4 | Narrow match/deletion race, exact restore of systemd states, rollback order | v0.9.4 |

Findings that turned out to describe older code were checked and noted as such, not acted on.
