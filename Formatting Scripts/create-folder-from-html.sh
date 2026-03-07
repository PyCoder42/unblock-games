#!/bin/zsh
#
# create-folder-from-html.sh
# Import a single HTML file into the locking protocol folder layout.
#
# Behavior:
# - Takes one HTML file input.
# - Normalizes that input into a clean protocol base file (*-regular.html).
# - If input already follows protocol (locked/open/banner markers), it first extracts base.
# - Creates/uses a destination folder and generates requested protocol variants.
#
# Usage:
#   ./create-folder-from-html.sh <input-file.html> [options]
#
# Options:
#   --versions <csv>   Extra variants to generate in addition to base.
#                      Allowed: open-in-new-tab,locked,locked-b64,base
#                      Default: locked-b64
#   --folder <name>    Override destination folder name (under --root unless absolute path)
#   --root <path>      Root folder for game folders (default: parent of script directory)
#   --password <value> Password override for generated locked variants
#   --dry-run          Print actions without changing files
#   --help             Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

check_dependencies

LOCK_SCRIPT="$SCRIPT_DIR/lock-game.sh"
ROOT_DIR="${SCRIPT_DIR:h}"

INPUT=""
VERSIONS_CSV="locked-b64"
FOLDER_OVERRIDE=""
PASSWORD_OVERRIDE=""
DRY_RUN="false"

usage() {
  cat <<'USAGE'
Usage: ./create-folder-from-html.sh <input-file.html> [options]

Options:
  --versions <csv>   Extra variants to generate (base is always created)
                     Allowed values: open-in-new-tab,locked,locked-b64,base
                     Default: locked-b64
  --folder <name>    Destination folder name (relative to --root unless absolute)
  --root <path>      Root directory for game folders (default: parent of script dir)
  --password <value> Password override for generated locked files
  --dry-run          Print actions without changing files
  --help             Show this help
USAGE
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# ── create-folder–specific helpers ───────────────────────────────

input_follows_protocol() {
  local file="$1"
  local stem="$2"
  local kind
  kind="$(variant_kind_from_stem "$stem")"
  if is_protocol_locked_b64 "$file"; then
    return 0
  fi
  if is_protocol_locked "$file"; then
    return 0
  fi
  if has_banner_markup "$file"; then
    return 0
  fi
  if has_trigger_comment "$file"; then
    return 0
  fi
  [[ "$kind" != "plain" ]]
}

title_case_slug() {
  local slug="$1"
  local spaced title
  spaced="$(printf '%s' "$slug" | sed -E 's/[-_]+/ /g; s/[[:space:]]+/ /g; s/^ +//; s/ +$//')"
  title="$(printf '%s' "$spaced" | awk '
    {
      for (i = 1; i <= NF; i++) {
        $i = toupper(substr($i,1,1)) tolower(substr($i,2));
      }
      print;
    }'
  )"
  print -r -- "$title"
}

find_existing_folder_for_regular() {
  local root="$1"
  local regular_file="$2"
  local d
  while IFS= read -r -d '' d; do
    if [[ -f "$d/$regular_file" ]]; then
      print -r -- "$d"
      return
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  print -r -- ""
}

call_lock_base() {
  local file="$1"
  if [[ -n "$PASSWORD_OVERRIDE" ]]; then
    run_cmd "$LOCK_SCRIPT" "$file" "$PASSWORD_OVERRIDE" "base"
  else
    run_cmd "$LOCK_SCRIPT" "$file" "" "base"
  fi
}

call_lock_variant() {
  local file="$1"
  local format="$2"
  if [[ -n "$PASSWORD_OVERRIDE" ]]; then
    run_cmd "$LOCK_SCRIPT" "$file" "$PASSWORD_OVERRIDE" "$format"
  else
    run_cmd "$LOCK_SCRIPT" "$file" "" "$format"
  fi
}

# ── Argument parsing ─────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --versions)
      [[ $# -ge 2 ]] || { err "--versions requires a value"; exit 1; }
      VERSIONS_CSV="$2"
      shift 2
      ;;
    --folder)
      [[ $# -ge 2 ]] || { err "--folder requires a value"; exit 1; }
      FOLDER_OVERRIDE="$(trim "$2")"
      shift 2
      ;;
    --root)
      [[ $# -ge 2 ]] || { err "--root requires a value"; exit 1; }
      ROOT_DIR="$2"
      shift 2
      ;;
    --password)
      [[ $# -ge 2 ]] || { err "--password requires a value"; exit 1; }
      PASSWORD_OVERRIDE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      err "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -n "$INPUT" ]]; then
        err "Only one input HTML file is allowed"
        usage
        exit 1
      fi
      INPUT="$1"
      shift
      ;;
  esac
done

if [[ -z "$INPUT" ]]; then
  err "Missing input file"
  usage
  exit 1
fi

[[ -x "$LOCK_SCRIPT" ]] || { err "lock-game.sh is missing or not executable: $LOCK_SCRIPT"; exit 1; }
[[ -d "$ROOT_DIR" ]] || { err "Root directory not found: $ROOT_DIR"; exit 1; }
[[ -f "$INPUT" ]] || { err "Input file not found: $INPUT"; exit 1; }

INPUT_NAME="${INPUT:t}"
INPUT_STEM="${INPUT_NAME:r}"
INPUT_EXT="${(L)${INPUT_NAME##*.}}"
[[ "$INPUT_EXT" == "html" ]] || { err "Input must be an .html file: $INPUT_NAME"; exit 1; }

if [[ "$INPUT" == /* ]]; then
  INPUT_ABS="$INPUT"
else
  INPUT_ABS="$(cd "${INPUT:h}" 2>/dev/null && pwd)/${INPUT:t}"
fi

typeset -a REQUESTED_VERSIONS
typeset -A VERSION_SEEN

for raw in ${(s:,:)VERSIONS_CSV}; do
  norm="$(normalize_variant_kind "$raw")"
  if [[ -z "$norm" ]]; then
    err "Invalid version kind: $raw"
    err "Allowed: open-in-new-tab,locked,locked-b64,base"
    exit 1
  fi
  if [[ "$norm" == "base" ]]; then
    continue
  fi
  if [[ -z "${VERSION_SEEN[$norm]-}" ]]; then
    REQUESTED_VERSIONS+=("$norm")
    VERSION_SEEN[$norm]=1
  fi
done

# ── Import workflow ──────────────────────────────────────────────

TMP_DIR="$(mktemp -d /tmp/create-folder-from-html.XXXXXX)"
create_folder_cleanup() {
  rm -rf "$TMP_DIR"
}
trap create_folder_cleanup EXIT

TMP_INPUT="$TMP_DIR/$INPUT_NAME"
cp "$INPUT_ABS" "$TMP_INPUT"

if input_follows_protocol "$INPUT_ABS" "$INPUT_STEM"; then
  log "Input appears to follow protocol; extracting a clean base before import."
else
  log "Input treated as base source; normalizing into protocol base format."
fi

call_lock_base "$TMP_INPUT" >/dev/null

TMP_REG_STEM="$(variant_stem_from_raw "$INPUT_STEM" "regular")"
TMP_BASE="$TMP_DIR/$TMP_REG_STEM.html"

if [[ ! -f "$TMP_BASE" ]]; then
  typeset -a REG_CANDIDATES
  REG_CANDIDATES=("$TMP_DIR"/*-regular*.html(N))
  if (( ${#REG_CANDIDATES[@]} == 1 )); then
    TMP_BASE="${REG_CANDIDATES[1]}"
    TMP_REG_STEM="${TMP_BASE:t:r}"
  else
    err "Could not find normalized base output in temporary workspace"
    exit 1
  fi
fi

BASE_CORE="$(variant_stem_from_raw "$TMP_REG_STEM" "base")"
DEST_REG_STEM="$(variant_stem_from_raw "$BASE_CORE" "regular")"
DEST_REG_FILE="$DEST_REG_STEM.html"

if [[ -z "$BASE_CORE" || -z "$DEST_REG_STEM" ]]; then
  err "Failed to derive protocol base name from input: $INPUT_NAME"
  exit 1
fi

if [[ -n "$FOLDER_OVERRIDE" ]]; then
  if [[ "$FOLDER_OVERRIDE" == /* ]]; then
    DEST_DIR="$FOLDER_OVERRIDE"
  else
    DEST_DIR="$ROOT_DIR/$FOLDER_OVERRIDE"
  fi
else
  INPUT_PARENT="${INPUT_ABS:h}"
  if [[ "${INPUT_PARENT:h}" == "$ROOT_DIR" && "${INPUT_PARENT:t}" != "Formatting Scripts" ]]; then
    DEST_DIR="$INPUT_PARENT"
  else
    EXISTING_DIR="$(find_existing_folder_for_regular "$ROOT_DIR" "$DEST_REG_FILE")"
    if [[ -n "$EXISTING_DIR" ]]; then
      DEST_DIR="$EXISTING_DIR"
    else
      FOLDER_NAME="$(title_case_slug "$BASE_CORE")"
      [[ -n "$FOLDER_NAME" ]] || FOLDER_NAME="Imported Game"
      DEST_DIR="$ROOT_DIR/$FOLDER_NAME"
    fi
  fi
fi

if [[ -e "$DEST_DIR" && ! -d "$DEST_DIR" ]]; then
  err "Destination exists and is not a directory: $DEST_DIR"
  exit 1
fi

run_cmd mkdir -p "$DEST_DIR"

DEST_BASE="$DEST_DIR/$DEST_REG_FILE"
run_cmd cp "$TMP_BASE" "$DEST_BASE"
log "Base file written: $DEST_BASE"

for kind in "${REQUESTED_VERSIONS[@]}"; do
  call_lock_variant "$DEST_BASE" "$kind" >/dev/null
  OUT_FILE="$DEST_DIR/$(variant_stem_from_raw "$BASE_CORE" "$kind").html"
  if [[ "$DRY_RUN" != "true" && ! -f "$OUT_FILE" ]]; then
    err "Expected output was not created: $OUT_FILE"
    exit 1
  fi
  log "Created: $OUT_FILE"
done

log "Import complete."
