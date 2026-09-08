#!/bin/sh
# Re-pins oc-pages to the head of the unfurl-gui branch named in package.json.
set -eu
cd "$(dirname "$0")/../.."

spec=$(node -p "require('./package.json').dependencies['oc-pages']")

yarn remove oc-pages
yarn add "oc-pages@$spec"
git commit -m 'oc: build: Update oc-pages to the latest unfurl-gui' package.json yarn.lock
