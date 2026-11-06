#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the release tarball for an existing tag.
#   scripts/make-release.sh v1.0.0
# Writes dist/kohaku-fprintd.tar.gz (unpacks to kohaku-fprintd-1.0.0/) and its .sha256.
set -euo pipefail

tag="${1:?usage: $0 <tag, e.g. v1.0.0>}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "tag $tag does not exist" >&2; exit 1; }
ver="${tag#v}"
name="kohaku-fprintd-$ver"
files=(cros-fprintd install.sh systemd/cros-fprintd.service udev/70-cros-fprintd.rules README.md LICENSE)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/$name"
git archive "$tag" -- "${files[@]}" | tar -x -C "$work/$name"
echo "$tag" > "$work/$name/VERSION"

mkdir -p dist
tar --owner=0 --group=0 --sort=name -C "$work" -czf dist/kohaku-fprintd.tar.gz "$name"
( cd dist && sha256sum kohaku-fprintd.tar.gz > kohaku-fprintd.tar.gz.sha256 )

echo "built dist/kohaku-fprintd.tar.gz from $tag:"
tar -tzf dist/kohaku-fprintd.tar.gz
cat dist/kohaku-fprintd.tar.gz.sha256
