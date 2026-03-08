#!/bin/zsh
#
# setup-secure.sh
# One-time setup for secure variant remote config.
# Configures dual-source (jsdelivr + Google Apps Script) and generates admin panel.
#
# Usage:
#   ./Formatting\ Scripts/setup-secure.sh
#
# Prerequisites:
#   1. A public GitHub repo with an empty config.json ({})
#   2. A GitHub PAT (Fine-grained, scoped to that repo, Contents read+write)
#   3. A Google Apps Script deployed as web app (paste gas-server.js)
#   4. GAS secret key set in Script Properties

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${SCRIPT_DIR:h}"
SECURE_CONFIG="$ROOT_DIR/.secure-config"
ADMIN_TEMPLATE="$SCRIPT_DIR/admin-panel-template.html"
ADMIN_OUTPUT="$ROOT_DIR/admin-panel.html"

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()  { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
err()  { printf "${RED}✗${NC} %s\n" "$*" >&2; }
ask()  { printf "${CYAN}?${NC} %s " "$1"; }

# ── Collect configuration ───────────────────────────────────────

printf "\n${CYAN}═══ Unblock Games Secure Variant Setup ═══${NC}\n\n"

# Check for existing config
if [[ -f "$SECURE_CONFIG" ]]; then
  warn "Existing .secure-config found. Values will be used as defaults."
  printf "\n"
fi

read_existing() {
  local key="$1"
  if [[ -f "$SECURE_CONFIG" ]]; then
    perl -ne "if (/^\\Q${key}\\E=(.+)/) { print \$1; exit }" "$SECURE_CONFIG"
  fi
}

# GitHub repo
DEFAULT_REPO="$(read_existing "GITHUB_REPO")"
ask "GitHub config repo (e.g., PyCoder42/ug-config)${DEFAULT_REPO:+ [$DEFAULT_REPO]}:"
read -r GITHUB_REPO
GITHUB_REPO="${GITHUB_REPO:-$DEFAULT_REPO}"
if [[ -z "$GITHUB_REPO" ]]; then
  err "GitHub repo is required."
  exit 1
fi

# GitHub PAT
DEFAULT_PAT="$(read_existing "GITHUB_PAT")"
ask "GitHub PAT (Fine-grained token)${DEFAULT_PAT:+ [****${DEFAULT_PAT: -4}]}:"
read -r GITHUB_PAT
GITHUB_PAT="${GITHUB_PAT:-$DEFAULT_PAT}"
if [[ -z "$GITHUB_PAT" ]]; then
  err "GitHub PAT is required."
  exit 1
fi

# GAS URL
DEFAULT_GAS="$(read_existing "GAS_URL")"
ask "Google Apps Script deployment URL${DEFAULT_GAS:+ [$DEFAULT_GAS]}:"
read -r GAS_URL
GAS_URL="${GAS_URL:-$DEFAULT_GAS}"
if [[ -z "$GAS_URL" ]]; then
  err "GAS URL is required."
  exit 1
fi

# GAS secret key
DEFAULT_SECRET="$(read_existing "GAS_SECRET")"
ask "GAS secret key (passphrase)${DEFAULT_SECRET:+ [****${DEFAULT_SECRET: -4}]}:"
read -r GAS_SECRET
GAS_SECRET="${GAS_SECRET:-$DEFAULT_SECRET}"
if [[ -z "$GAS_SECRET" ]]; then
  err "GAS secret key is required."
  exit 1
fi

# Derive jsdelivr URL
JSDELIVR_URL="https://cdn.jsdelivr.net/gh/${GITHUB_REPO}@main/config.json"

printf "\n"
log "jsdelivr URL: $JSDELIVR_URL"
log "GAS URL:      $GAS_URL"
log "GitHub repo:  $GITHUB_REPO"

# ── Test connections ────────────────────────────────────────────

printf "\n${CYAN}Testing connections...${NC}\n"

# Test GitHub API access
printf "  Testing GitHub API... "
GITHUB_API_RESP="$(curl -sf -o /dev/null -w "%{http_code}" \
  -H "Authorization: token $GITHUB_PAT" \
  "https://api.github.com/repos/$GITHUB_REPO" 2>/dev/null || true)"

if [[ "$GITHUB_API_RESP" == "200" ]]; then
  printf "${GREEN}OK${NC}\n"
else
  printf "${YELLOW}HTTP $GITHUB_API_RESP${NC}\n"
  warn "GitHub API returned $GITHUB_API_RESP — check repo name and PAT permissions."
  ask "Continue anyway? (y/N):"
  read -r cont
  [[ "${cont:-n}" == [yY]* ]] || exit 1
fi

# Test GAS endpoint
printf "  Testing GAS endpoint... "
GAS_RESP="$(curl -sf -L "$GAS_URL?action=read&callback=test" 2>/dev/null || true)"
if [[ -n "$GAS_RESP" && "$GAS_RESP" == test\(* ]]; then
  printf "${GREEN}OK${NC}\n"
else
  printf "${YELLOW}No valid JSONP response${NC}\n"
  warn "GAS returned: ${GAS_RESP:0:80}"
  ask "Continue anyway? (y/N):"
  read -r cont
  [[ "${cont:-n}" == [yY]* ]] || exit 1
fi

# ── Scan game folders ───────────────────────────────────────────

printf "\n${CYAN}Scanning game folders...${NC}\n"

source "$SCRIPT_DIR/common.sh"

typeset -a GAME_IDS
while IFS= read -r -d '' d; do
  dir_name="${d:t}"
  [[ "$dir_name" == .* ]] && continue
  [[ "$dir_name" == "Formatting Scripts" ]] && continue
  [[ "$dir_name" == "Pokemon Showdown" ]] && continue
  [[ "$dir_name" == "test-lock-converter" ]] && continue

  # Find regular files and derive game IDs
  while IFS= read -r -d '' f; do
    stem="${f:t:r}"
    kind="$(variant_kind_from_stem "$stem")"
    if [[ "$kind" == "regular" ]]; then
      base="$(derive_standard_base "$stem")"
      if [[ -n "$base" ]]; then
        GAME_IDS+=("$base")
      fi
    fi
  done < <(find "$d" -maxdepth 1 -type f -name '*-regular.html' -print0 | sort -z)
done < <(find "$ROOT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if (( ${#GAME_IDS[@]} == 0 )); then
  warn "No game folders found. Games list will be empty."
fi

# Build JSON games array
GAMES_JSON="["
for i in "${!GAME_IDS[@]}"; do
  (( i > 0 )) && GAMES_JSON+=","
  GAMES_JSON+="\"${GAME_IDS[$i]}\""
done
GAMES_JSON+="]"

log "Found ${#GAME_IDS[@]} games: ${GAME_IDS[*]}"

# ── Initialize config in both sources ───────────────────────────

DEFAULT_PASSWORD="supercoolpassword"
CONFIG_JSON="{\"password\":\"$DEFAULT_PASSWORD\",\"blocked\":{},\"games\":$GAMES_JSON}"

printf "\n${CYAN}Initializing remote config...${NC}\n"

# Initialize GitHub config.json
printf "  Writing to GitHub... "

# Check if config.json already exists (need SHA for update)
EXISTING_SHA=""
EXISTING_RESP="$(curl -sf \
  -H "Authorization: token $GITHUB_PAT" \
  "https://api.github.com/repos/$GITHUB_REPO/contents/config.json" 2>/dev/null || true)"

if [[ -n "$EXISTING_RESP" ]]; then
  EXISTING_SHA="$(printf '%s' "$EXISTING_RESP" | perl -ne 'if (/"sha"\s*:\s*"([a-f0-9]+)"/) { print $1; exit }')"
fi

CONFIG_B64="$(printf '%s' "$CONFIG_JSON" | base64 | tr -d '\n')"

PUT_BODY="{\"message\":\"Initialize secure config\",\"content\":\"$CONFIG_B64\""
if [[ -n "$EXISTING_SHA" ]]; then
  PUT_BODY+=",\"sha\":\"$EXISTING_SHA\""
fi
PUT_BODY+="}"

GITHUB_PUT_RESP="$(curl -sf -o /dev/null -w "%{http_code}" \
  -X PUT \
  -H "Authorization: token $GITHUB_PAT" \
  -H "Content-Type: application/json" \
  -d "$PUT_BODY" \
  "https://api.github.com/repos/$GITHUB_REPO/contents/config.json" 2>/dev/null || true)"

if [[ "$GITHUB_PUT_RESP" == "200" || "$GITHUB_PUT_RESP" == "201" ]]; then
  printf "${GREEN}OK${NC}\n"
else
  printf "${YELLOW}HTTP $GITHUB_PUT_RESP${NC}\n"
  warn "Failed to write config.json to GitHub. You may need to do this manually."
fi

# Purge jsdelivr cache
printf "  Purging jsdelivr cache... "
curl -sf "https://purge.jsdelivr.net/gh/$GITHUB_REPO@main/config.json" > /dev/null 2>&1 || true
printf "${GREEN}OK${NC}\n"

# Initialize GAS config
printf "  Writing to GAS... "
ENCODED_CONFIG="$(printf '%s' "$CONFIG_JSON" | perl -MURI::Escape -ne 'print uri_escape($_)')"
GAS_WRITE_RESP="$(curl -sf -L \
  "$GAS_URL?action=write&key=$GAS_SECRET&writeAction=fullSync&config=$ENCODED_CONFIG&callback=test" \
  2>/dev/null || true)"

if [[ "$GAS_WRITE_RESP" == *'"success"'* ]]; then
  printf "${GREEN}OK${NC}\n"
else
  printf "${YELLOW}Unexpected response${NC}\n"
  warn "GAS write returned: ${GAS_WRITE_RESP:0:80}"
fi

# ── Write .secure-config ────────────────────────────────────────

printf "\n${CYAN}Writing .secure-config...${NC}\n"

cat > "$SECURE_CONFIG" <<EOF
JSDELIVR_URL=$JSDELIVR_URL
GAS_URL=$GAS_URL
GITHUB_REPO=$GITHUB_REPO
GITHUB_PAT=$GITHUB_PAT
GAS_SECRET=$GAS_SECRET
EOF

log "Saved to $SECURE_CONFIG"

# ── Generate admin panel ────────────────────────────────────────

printf "\n${CYAN}Generating admin panel...${NC}\n"

if [[ ! -f "$ADMIN_TEMPLATE" ]]; then
  warn "Admin panel template not found at: $ADMIN_TEMPLATE"
  warn "Run this again after creating the template."
else
  sed \
    -e "s|{{JSDELIVR_URL}}|$JSDELIVR_URL|g" \
    -e "s|{{GAS_URL}}|$GAS_URL|g" \
    -e "s|{{GITHUB_REPO}}|$GITHUB_REPO|g" \
    -e "s|{{GITHUB_PAT}}|$GITHUB_PAT|g" \
    -e "s|{{GAS_SECRET}}|$GAS_SECRET|g" \
    "$ADMIN_TEMPLATE" > "$ADMIN_OUTPUT"
  log "Generated: $ADMIN_OUTPUT"
fi

# ── Summary ─────────────────────────────────────────────────────

printf "\n${GREEN}═══ Setup Complete ═══${NC}\n\n"
printf "  Config repo:    https://github.com/$GITHUB_REPO\n"
printf "  jsdelivr URL:   $JSDELIVR_URL\n"
printf "  GAS URL:        $GAS_URL\n"
printf "  Games:          ${GAME_IDS[*]}\n"
printf "  Password:       $DEFAULT_PASSWORD\n"
printf "  Admin panel:    $ADMIN_OUTPUT\n"
printf "\n"
printf "Next steps:\n"
printf "  1. Generate secure files:  ./Formatting Scripts/sync-protocol-versions.sh --keep base,locked-b64,secure --force\n"
printf "  2. Open admin-panel.html to manage games remotely\n"
printf "\n"
