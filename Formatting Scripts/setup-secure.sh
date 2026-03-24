#!/bin/zsh
#
# setup-secure.sh
# One-time setup for secure variant remote config.
# Configures multi-provider (jsdelivr + GitHub raw + unpkg) and generates admin panel.
#
# Usage:
#   ./Formatting\ Scripts/setup-secure.sh                              # Full interactive setup
#   ./Formatting\ Scripts/setup-secure.sh --regenerate                 # Regenerate admin panel from template
#   ./Formatting\ Scripts/setup-secure.sh --fake "Label" [github-pat]  # Create a fake admin panel
#
# Prerequisites:
#   1. A public GitHub repo with an empty config.json ({})
#   2. A GitHub PAT (Fine-grained, scoped to that repo, Contents read+write)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${SCRIPT_DIR:h}"
SECURE_CONFIG="$ROOT_DIR/.secure-config"
ADMIN_TEMPLATE="$SCRIPT_DIR/admin-panel-template.html"
ADMIN_OUTPUT="$ROOT_DIR/Admin Panel/admin-panel.html"
ADMIN_DIR="$ROOT_DIR/Admin Panel"

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

read_existing() {
  local key="$1"
  if [[ -f "$SECURE_CONFIG" ]]; then
    perl -ne "if (/^\\Q${key}\\E=(.+)/) { print \$1; exit }" "$SECURE_CONFIG"
  fi
}

generate_admin_panel() {
  local panel_mode="$1"
  local github_pat="$2"
  local output_file="$3"

  local jsdelivr_url="$(read_existing "JSDELIVR_URL")"
  local github_repo="$(read_existing "GITHUB_REPO")"
  local github_raw_url="$(read_existing "GITHUB_RAW_URL")"
  local unpkg_url="$(read_existing "UNPKG_URL")"

  if [[ -z "$github_raw_url" && -n "$github_repo" ]]; then
    github_raw_url="https://raw.githubusercontent.com/${github_repo}/main/config.json"
  fi

  if [[ -z "$unpkg_url" ]]; then
    unpkg_url="https://unpkg.com/@pycoder42/ug-config@latest/config.json"
  fi

  if [[ ! -f "$ADMIN_TEMPLATE" ]]; then
    err "Admin panel template not found at: $ADMIN_TEMPLATE"
    return 1
  fi

  mkdir -p "$(dirname "$output_file")"

  sed \
    -e "s|{{JSDELIVR_URL}}|$jsdelivr_url|g" \
    -e "s|{{GITHUB_RAW_URL}}|$github_raw_url|g" \
    -e "s|{{UNPKG_URL}}|$unpkg_url|g" \
    -e "s|{{GITHUB_REPO}}|$github_repo|g" \
    -e "s|{{GITHUB_PAT}}|$github_pat|g" \
    -e "s|{{PANEL_MODE}}|$panel_mode|g" \
    "$ADMIN_TEMPLATE" > "$output_file"
}

# DJB2 hash → base36, first 6 chars (must match keyIdentifier in gas-server.js)
key_identifier() {
  perl -e '
    my $key = $ARGV[0];
    my $hash = 5381;
    for my $ch (split //, $key) {
      $hash = (($hash << 5) + $hash + ord($ch)) & 0x7fffffff;
    }
    my $result = "";
    my @chars = split //, "0123456789abcdefghijklmnopqrstuvwxyz";
    my $tmp = $hash;
    while ($tmp > 0) {
      $result = $chars[$tmp % 36] . $result;
      $tmp = int($tmp / 36);
    }
    print substr($result, 0, 6);
  ' "$1"
}

# ── Handle --regenerate ────────────────────────────────────────
if [[ "${1:-}" == "--regenerate" ]]; then
  printf "\n${CYAN}═══ Regenerating Admin Panel ═══${NC}\n\n"

  if [[ ! -f "$SECURE_CONFIG" ]]; then
    err ".secure-config not found. Run full setup first."
    exit 1
  fi

  generate_admin_panel \
    "real" \
    "$(read_existing "GITHUB_PAT")" \
    "$ADMIN_OUTPUT"

  log "Regenerated: $ADMIN_OUTPUT"
  exit 0
fi

# ── Handle --fake ──────────────────────────────────────────────
if [[ "${1:-}" == "--fake" ]]; then
  FAKE_LABEL="${2:-}"
  FAKE_PAT="${3:-}"

  if [[ -z "$FAKE_LABEL" ]]; then
    err "Usage: $0 --fake \"Label\" [github-pat]"
    err "  If no PAT provided, you'll be prompted for one."
    exit 1
  fi

  printf "\n${CYAN}═══ Creating Fake Admin Panel ═══${NC}\n\n"

  if [[ ! -f "$SECURE_CONFIG" ]]; then
    err ".secure-config not found. Run full setup first."
    exit 1
  fi

  if [[ -z "$FAKE_PAT" ]]; then
    ask "GitHub PAT for this fake panel (create a fine-grained token at github.com/settings/tokens):"
    read -r FAKE_PAT
  fi

  if [[ -z "$FAKE_PAT" ]]; then
    err "A GitHub PAT is required for fake panels."
    exit 1
  fi

  # Generate identifier from label
  FAKE_ID="$(key_identifier "$FAKE_LABEL")"

  # Generate fake admin panel
  FAKE_OUTPUT="$ADMIN_DIR/admin-panel-$FAKE_ID.html"

  generate_admin_panel "fake" "$FAKE_PAT" "$FAKE_OUTPUT"

  log "Generated: $FAKE_OUTPUT"

  printf "\n${GREEN}═══ Fake Admin Panel Created ═══${NC}\n\n"
  printf "  File:       $FAKE_OUTPUT\n"
  printf "  Identifier: $FAKE_ID\n"
  printf "  Label:      $FAKE_LABEL\n"
  printf "\n"
  printf "  The fake panel uses its own GitHub PAT.\n"
  printf "  To revoke access: delete the PAT at github.com/settings/tokens\n"
  printf "\n"
  exit 0
fi

# ── Collect configuration (full interactive setup) ─────────────

printf "\n${CYAN}═══ Unblock Games Secure Variant Setup ═══${NC}\n\n"

# Check for existing config
if [[ -f "$SECURE_CONFIG" ]]; then
  warn "Existing .secure-config found. Values will be used as defaults."
  printf "\n"
fi

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

# Derive URLs
JSDELIVR_URL="https://cdn.jsdelivr.net/gh/${GITHUB_REPO}@latest/config.json"
GITHUB_RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/config.json"
DEFAULT_UNPKG_URL="$(read_existing "UNPKG_URL")"
UNPKG_URL="${DEFAULT_UNPKG_URL:-https://unpkg.com/@pycoder42/ug-config@latest/config.json}"

printf "\n"
log "jsdelivr URL:   $JSDELIVR_URL"
log "GitHub raw URL: $GITHUB_RAW_URL"
log "unpkg URL:      $UNPKG_URL"
log "GitHub repo:    $GITHUB_REPO"

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

# ── Scan game folders ───────────────────────────────────────────

printf "\n${CYAN}Scanning game folders...${NC}\n"

source "$SCRIPT_DIR/common.sh"

typeset -a GAME_IDS
while IFS= read -r -d '' d; do
  dir_name="${d:t}"
  [[ "$dir_name" == .* ]] && continue
  [[ "$dir_name" == "Formatting Scripts" ]] && continue
  [[ "$dir_name" == "Admin Panel" ]] && continue
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
CONFIG_JSON="{\"password\":\"$DEFAULT_PASSWORD\",\"passwords\":[\"$DEFAULT_PASSWORD\"],\"blocked\":{},\"games\":$GAMES_JSON,\"allowedIps\":{}}"

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
curl -sf "https://purge.jsdelivr.net/gh/$GITHUB_REPO@latest/config.json" > /dev/null 2>&1 || true
printf "${GREEN}OK${NC}\n"

# ── Write .secure-config ────────────────────────────────────────

printf "\n${CYAN}Writing .secure-config...${NC}\n"

cat > "$SECURE_CONFIG" <<EOF
JSDELIVR_URL=$JSDELIVR_URL
GITHUB_REPO=$GITHUB_REPO
GITHUB_PAT=$GITHUB_PAT
GITHUB_RAW_URL=$GITHUB_RAW_URL
UNPKG_URL=$UNPKG_URL
EOF

log "Saved to $SECURE_CONFIG"

# ── Generate admin panel ────────────────────────────────────────

printf "\n${CYAN}Generating admin panel...${NC}\n"

generate_admin_panel "real" "$GITHUB_PAT" "$ADMIN_OUTPUT"
log "Generated: $ADMIN_OUTPUT"

# ── Summary ─────────────────────────────────────────────────────

printf "\n${GREEN}═══ Setup Complete ═══${NC}\n\n"
printf "  Config repo:    https://github.com/$GITHUB_REPO\n"
printf "  jsdelivr URL:   $JSDELIVR_URL\n"
printf "  GitHub raw URL: $GITHUB_RAW_URL\n"
printf "  unpkg URL:      $UNPKG_URL\n"
printf "  Games:          ${GAME_IDS[*]}\n"
printf "  Password:       $DEFAULT_PASSWORD\n"
printf "  Admin panel:    $ADMIN_OUTPUT\n"
printf "\n"
printf "Next steps:\n"
printf "  1. Generate secure files:  ./Formatting Scripts/sync-protocol-versions.sh --keep base,locked-b64,secure --force\n"
printf "  2. Sync remote config:     node \"Formatting Scripts/sync-remote-config.mjs\"\n"
printf "  3. Open admin-panel.html to manage games remotely\n"
printf "\n"
