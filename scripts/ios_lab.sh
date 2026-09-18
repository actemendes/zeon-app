#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/apple/env.sh"
exec python3 "${SCRIPT_DIR}/ios_lab.py" "$@"
