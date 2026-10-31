#!/usr/bin/env bash
# OC Change: Yarn 3 runs package.json scripts in its own shell, which has no if/else.

set -euo pipefail

if [[ "${ENABLE_RSPACK:-}" == "true" ]]; then
  exec yarn run rspack
fi

exec yarn run webpack
