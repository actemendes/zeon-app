#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test -x "${ROOT}/scripts/build.sh"
test -x "${ROOT}/scripts/apple/build.sh"
bash -n "${ROOT}/scripts/build.sh" "${ROOT}/scripts/apple/build.sh"
help="$("${ROOT}/scripts/build.sh" help)"
[[ "${help}" == *ios-device* && "${help}" == *out/installers* ]]
if "${ROOT}/scripts/build.sh" invalid-test-action >/dev/null 2>&1; then
  echo 'Unknown action unexpectedly succeeded' >&2
  exit 1
else
  test "$?" -eq 2
fi
echo 'Apple entrypoint checks passed'
