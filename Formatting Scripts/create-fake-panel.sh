#!/bin/zsh
#
# create-fake-panel.sh
# Creates a fake admin panel with its own GitHub PAT.
# This is a convenience wrapper around setup-secure.sh --fake.
#
# Usage:
#   ./Formatting\ Scripts/create-fake-panel.sh "Person's Name" [github-pat]
#
# To revoke access, delete the PAT at github.com/settings/tokens
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 \"Label\" [github-pat]"
  echo ""
  echo "Creates a fake admin panel with a separate GitHub PAT."
  echo "To revoke access later, delete the PAT at github.com/settings/tokens"
  echo ""
  echo "Steps to create a PAT:"
  echo "  1. Go to github.com/settings/tokens?type=beta"
  echo "  2. Click 'Generate new token'"
  echo "  3. Name it after the person (e.g., 'Admin Panel - John')"
  echo "  4. Set repository access to your config repo only"
  echo "  5. Under 'Repository permissions', set 'Contents' to 'Read and write'"
  echo "  6. Generate and copy the token"
  exit 1
fi

exec "$SCRIPT_DIR/setup-secure.sh" --fake "$@"
