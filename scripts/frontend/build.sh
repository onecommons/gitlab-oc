#!/usr/bin/env bash
# OC Change: Yarn 3 runs package.json scripts in its own shell, which has no if/else.
# Rspack is the default because oc-pages builds only with it; ENABLE_RSPACK=false
# selects Webpack, as it does for WebpackHelper#rspack_enabled?.

set -euo pipefail

# Matches the false values of Gitlab::Utils.to_boolean, which reads the same variable.
shopt -s nocasematch
if [[ "${ENABLE_RSPACK:-}" =~ ^(false|f|no|n|0|off)$ ]]; then
  exec yarn run webpack
fi

exec yarn run rspack
