#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# [doc:tst-doc-tags]
# Every [doc:<id>] tag in the code has an entry in docs/CODE.md, and every entry still
# has a tag in the code; each ID is used exactly once.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
code_ids="$(grep -rhoE '\[doc:[a-z0-9-]+\]' --exclude-dir=docs --exclude-dir=.git . | sed 's/\[doc:\(.*\)\]/\1/' | sort)"
doc_ids="$(grep -oE '<a id="[a-z0-9-]+"></a>' docs/CODE.md | sed 's/<a id="\(.*\)"><\/a>/\1/' | sort)"
FAILED=0
dups="$(printf '%s\n' "$code_ids" | uniq -d)"
[ -z "$dups" ] || { echo "FAIL tag used more than once: $dups"; FAILED=1; }
missing="$(comm -23 <(printf '%s\n' "$code_ids" | sort -u) <(printf '%s\n' "$doc_ids"))"
[ -z "$missing" ] || { echo "FAIL tags without an entry in docs/CODE.md: $missing"; FAILED=1; }
stale="$(comm -13 <(printf '%s\n' "$code_ids" | sort -u) <(printf '%s\n' "$doc_ids"))"
[ -z "$stale" ] || { echo "FAIL entries in docs/CODE.md without a tag: $stale"; FAILED=1; }
[ "$FAILED" -eq 0 ] && echo "PASS $(printf '%s\n' "$code_ids" | wc -l) tags match docs/CODE.md"
echo "RESULT: $([ "$FAILED" -eq 0 ] && echo "ALL PASSED" || echo FAILED)"
exit "$FAILED"
