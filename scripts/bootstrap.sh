#!/usr/bin/env bash
set -euo pipefail

required_flutter="$(sed -n '/^environment:/,/^[^[:space:]]/ s/^[[:space:]]*flutter:[[:space:]]*\^*\([0-9.]\+\).*$/\1/p' pubspec.yaml | head -n1)"
if [[ -z "${required_flutter}" ]]; then
  echo "Failed to detect required Flutter version from pubspec.yaml" >&2
  exit 1
fi

echo "Sync git submodules..."
if [[ ! -f "hiddify-core/v2/config/builder.go" ]]; then
  echo "hiddify-core directory is missing. Make sure repository contains vendored hiddify-core." >&2
  exit 1
fi
echo "Vendored hiddify-core found."

echo "Validate Flutter version..."
actual_flutter="$(flutter --version --machine | sed -n 's/.*"frameworkVersion":"\([^"]*\)".*/\1/p')"
if [[ -z "${actual_flutter}" ]]; then
  echo "Flutter is not available in PATH" >&2
  exit 1
fi

case "${actual_flutter}" in
  "${required_flutter}"*)
    echo "Flutter version OK: ${actual_flutter}"
    ;;
  *)
    echo "Flutter version mismatch. Required ${required_flutter}.x, got ${actual_flutter}" >&2
    exit 1
    ;;
esac

echo "Resolve dependencies with lockfile..."
flutter pub get --enforce-lockfile

echo "Bootstrap completed."
