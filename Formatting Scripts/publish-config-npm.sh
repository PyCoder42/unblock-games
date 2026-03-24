#!/bin/zsh
#
# publish-config-npm.sh
# Copy the current config into config-pkg/, bump the patch version, and publish to npm.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${SCRIPT_DIR:h}"
PACKAGE_DIR="$ROOT_DIR/config-pkg"
PACKAGE_JSON="$PACKAGE_DIR/package.json"
PACKAGE_CONFIG="$PACKAGE_DIR/config.json"

if [[ ! -f "$PACKAGE_JSON" ]]; then
  echo "Error: Missing $PACKAGE_JSON"
  exit 1
fi

SOURCE_CONFIG="$ROOT_DIR/config.json"
if [[ ! -f "$SOURCE_CONFIG" ]]; then
  SOURCE_CONFIG="$ROOT_DIR/Games/config.json"
fi

if [[ ! -f "$SOURCE_CONFIG" ]]; then
  echo "Error: Could not find config.json in root or Games/"
  exit 1
fi

mkdir -p "$PACKAGE_DIR"
cp "$SOURCE_CONFIG" "$PACKAGE_CONFIG"

node - "$PACKAGE_JSON" <<'EOF_NODE'
const fs = require('node:fs');

const packagePath = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
const version = String(pkg.version || '0.0.0').split('.');
const major = Number(version[0] || 0);
const minor = Number(version[1] || 0);
const patch = Number(version[2] || 0) + 1;
pkg.version = [major, minor, patch].join('.');
fs.writeFileSync(packagePath, JSON.stringify(pkg, null, 2) + '\n');
console.log(pkg.version);
EOF_NODE

cd "$PACKAGE_DIR"
npm publish
