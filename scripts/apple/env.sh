#!/usr/bin/env bash

if [[ -n "${ZSH_VERSION:-}" ]]; then
  APPLE_ENV_FILE="${(%):-%N}"
else
  APPLE_ENV_FILE="${BASH_SOURCE[0]}"
fi

APPLE_SCRIPTS_DIR="$(cd "$(dirname "${APPLE_ENV_FILE}")" && pwd)"
PROJECT_ROOT="$(cd "${APPLE_SCRIPTS_DIR}/../.." && pwd)"
TOOLCHAINS_DIR="${PROJECT_ROOT}/.toolchains"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PUB_CACHE="${PUB_CACHE:-${TOOLCHAINS_DIR}/pub-cache}"
export GEM_HOME="${GEM_HOME:-${TOOLCHAINS_DIR}/gems}"
export GEM_PATH="${GEM_PATH:-${GEM_HOME}}"
export GEM_SPEC_CACHE="${GEM_SPEC_CACHE:-${TOOLCHAINS_DIR}/gem-spec-cache}"
export GOPATH="${GOPATH:-${TOOLCHAINS_DIR}/gopath}"
export RUBYOPT="${RUBYOPT:--rlogger}"
export FLUTTER_SUPPRESS_ANALYTICS=true
export COCOAPODS_DISABLE_STATS=true

export PATH="${TOOLCHAINS_DIR}/flutter/bin:${TOOLCHAINS_DIR}/go/bin:${GEM_HOME}/bin:${PUB_CACHE}/bin:${GOPATH}/bin:${PATH}"

export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
