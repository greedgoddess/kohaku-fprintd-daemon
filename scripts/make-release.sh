#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the release tarball for an existing tag.
#   scripts/make-release.sh v0.9.0
# Writes dist/kohaku-fprintd.tar.gz (unpacks to kohaku-fprintd-0.9.0/) and its .sha256.
#
# - Only the user-facing files are packed, taken from the tag (not the working tree).
# - The repository at the tag is scanned for secrets and private data first.
# - The archive is reproducible: same tag -> byte-identical tarball and checksum.
# - A signed tag is verified; an unsigned one gives a warning.
set -euo pipefail

tag="${1:?usage: $0 <tag, e.g. v0.9.0>}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "tag $tag does not exist" >&2; exit 1; }
commit="$(git rev-list -n 1 "$tag")"
ver="${tag#v}"
name="kohaku-fprintd-$ver"
files=(cros-fprintd install.sh systemd/cros-fprintd.service udev/70-cros-fprintd.rules README.md LICENSE)

# --- provenance: verify the tag signature if there is one
if git cat-file tag "$tag" 2>/dev/null | grep -qE 'BEGIN (PGP|SSH) SIGNATURE'; then
    git tag -v "$tag" >/dev/null 2>&1 || { echo "tag $tag has a signature that does not verify" >&2; exit 1; }
    echo "tag $tag: signature verified"
else
    echo "WARNING: tag $tag is not signed (see README, Releasing)" >&2
fi

# --- secret scan over everything tracked at the tag
bad_files="$(git ls-tree -r --name-only "$tag" | grep -E '(^|/)(seed(\.bin)?|template[0-9]*\.bin)$|\.(bin|pem|key)$' || true)"
if [ -n "$bad_files" ]; then
    echo "refusing to release: private-looking files are tracked at $tag:" >&2
    echo "$bad_files" >&2
    exit 1
fi
secret_re='BEGIN [A-Z ]*PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}'
if git grep -I -n -E "$secret_re" "$tag" -- . >/dev/null 2>&1; then
    echo "refusing to release: possible secrets found at $tag:" >&2
    git grep -I -n -E "$secret_re" "$tag" -- . >&2
    exit 1
fi
echo "secret scan: clean"

# --- reproducible archive
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/$name"
git archive "$tag" -- "${files[@]}" | tar -x -C "$work/$name"
printf '%s %s\n' "$tag" "$commit" > "$work/$name/VERSION"
epoch="$(git log -1 --format=%ct "$commit")"

mkdir -p dist
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -C "$work" -cf - "$name" | gzip -n -9 > dist/kohaku-fprintd.tar.gz
( cd dist && sha256sum kohaku-fprintd.tar.gz > kohaku-fprintd.tar.gz.sha256 )

echo "built dist/kohaku-fprintd.tar.gz from $tag ($commit):"
tar -tzf dist/kohaku-fprintd.tar.gz
cat dist/kohaku-fprintd.tar.gz.sha256
