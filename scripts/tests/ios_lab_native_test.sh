#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/apple/env.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/zeon-ios-evidence-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc "$ROOT/ios/LabTests/IosLabEvidence.swift" \
  "$ROOT/scripts/tests/ios_lab_native_test.swift" -o "$scratch/evidence-tests"
"$scratch/evidence-tests"
