#!/usr/bin/env bash
#
# Build and run a consumer of the PUBLISHED package.
#
# Why this exists
# ---------------
# `moon check` inside this repository proves that the source compiles and
# `moon test` proves that the source behaves. Neither proves that the
# *published artifact* is usable from another MoonBit project: the module
# metadata that a consumer actually resolves -- the package path,
# `supported_targets = "+native"`, the dependency pins -- exists only in
# the registry copy. That is exactly where a packaging mistake hides.
#
# So this script does what a real consumer does:
#
#   1. scaffold a throwaway MoonBit module,
#   2. `moon add riantr/moonbit_labeler` -- resolved from mooncakes.io,
#      NOT from this source tree,
#   3. drop in the very same sample that lives in examples/consumer/,
#   4. `moon check --target native` and then `moon run`, and
#   5. assert that the op list and a label round-trip came back.
#
# Usage: examples/consumer/run.sh [version]
#
#   version   the version to test. Defaults to the version declared in
#             moon.mod when it is already published, otherwise to the
#             latest published version (a version that has been bumped in
#             moon.mod but not yet released is, by definition, not
#             consumable).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

sample="$work/app"
moon new "$sample" --user riantr --name moonbit_labeler_consumer >/dev/null

cd "$sample"

# --- resolve the dependency from the registry ------------------------------
declared="$(sed -n 's/^version = "\(.*\)"/\1/p' "$repo/moon.mod" | head -n1)"
version="${1:-$declared}"

if [ -n "$version" ]; then
  echo "==> moon add riantr/moonbit_labeler@$version"
  # A failed `moon add` leaves moon.mod untouched, so falling back to the
  # unversioned add below is safe.
  if ! moon add "riantr/moonbit_labeler@$version"; then
    echo "!! $version is not published yet; testing the latest published version"
    version=""
    moon add riantr/moonbit_labeler
  fi
else
  echo "==> moon add riantr/moonbit_labeler (latest published)"
  moon add riantr/moonbit_labeler
fi

resolved="$(sed -n 's/.*"riantr\/moonbit_labeler@\([^"]*\)".*/\1/p' moon.mod | head -n1)"
echo "==> resolved version: ${resolved:-unknown}"

# --- install the sample ----------------------------------------------------
# Same two files as the in-repo package, so the README, the CI job and the
# published-artifact check can never drift apart.
mkdir -p cmd/main
cp "$here/moon.pkg" cmd/main/moon.pkg
cp "$here/main.mbt" cmd/main/main.mbt

# --- check, build, run -----------------------------------------------------
echo "==> moon check --target native"
moon check --target native --diagnostic-limit 40

echo "==> moon run cmd/main --target native"
output="$(moon run cmd/main --target native)"
echo "$output"

# --- assert ----------------------------------------------------------------
# The op count is the package's own contract with the frontend; the label
# round-trip proves the dispatcher works end to end.
if ! grep -q '^op count = 27$' <<<"$output"; then
  echo "FAIL: expected 'op count = 27'" >&2
  exit 1
fi
if ! grep -q 'probe.png' <<<"$output"; then
  echo "FAIL: expected the label round-trip to mention probe.png" >&2
  exit 1
fi

echo "PASS: the published package is consumable (version ${resolved:-unknown})"
