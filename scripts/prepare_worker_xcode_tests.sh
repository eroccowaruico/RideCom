#!/bin/sh
set -eu

export PATH="${TEST_RUNNER_PATH:-$PATH}:/opt/homebrew/bin:/usr/local/bin"
cd "$SRCROOT"
python3 -c 'from scripts.validate import verify_node; verify_node()'
node_path=$(command -v node)

cd server
if ! cmp -s package-lock.json node_modules/.xcode-worker-package-lock.json \
    || ! cmp -s package.json node_modules/.xcode-worker-package.json \
    || ! test -f node_modules/wrangler/bin/wrangler.js; then
    npm ci --no-audit --no-fund
    cp package-lock.json node_modules/.xcode-worker-package-lock.json
    cp package.json node_modules/.xcode-worker-package.json
fi
WRANGLER_SEND_METRICS=false "$node_path" node_modules/wrangler/bin/wrangler.js deploy --dry-run --outdir dist

mkdir -p "$(dirname "$SCRIPT_OUTPUT_FILE_0")"
generated=$(mktemp "${SCRIPT_OUTPUT_FILE_0}.XXXXXXXX")
trap 'rm -f "$generated"' EXIT
"$node_path" test/generate-xcode-cases.mjs > "$generated"
if ! cmp -s "$generated" "$SCRIPT_OUTPUT_FILE_0"; then
    mv "$generated" "$SCRIPT_OUTPUT_FILE_0"
fi
