#!/bin/zsh
#
# sync-protocol-versions.sh
# Scan top-level folders and normalize HTML files to protocol variants.
#
# Default keep set: base,locked-b64
#
# Examples:
#   ./sync-protocol-versions.sh
#   ./sync-protocol-versions.sh --keep base,locked-b64 --dry-run
#   ./sync-protocol-versions.sh --keep base,open-in-new-tab,locked,locked-b64 --force

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

check_dependencies

KEEP_CSV="base,locked,secure"
PASSWORD_OVERRIDE=""
DRY_RUN="false"
FORCE_REGENERATE="false"
UPGRADE_BANNER="true"
INCLUDE_DIRS=""
EXCLUDE_DIRS="test-lock-converter,Formatting Scripts"

LOCK_SCRIPT="$SCRIPT_DIR/lock-game.sh"
ROOT_DIR="${SCRIPT_DIR:h}"

usage() {
  cat <<'USAGE'
Usage: ./sync-protocol-versions.sh [options]

Options:
  --root <path>        Root directory to scan (default: parent of script dir)
  --keep <csv>         Variants to keep:
                       base,open-in-new-tab,locked,locked-b64,secure
                       (default: base,locked-b64)
  --password <value>   Override password for generated locked files
  --dry-run            Print actions without changing files
  --force              Regenerate kept variants even if they already exist
  --upgrade-banner     Upgrade existing banner files to latest shared banner controls
                       (default: enabled)
  --no-upgrade-banner  Skip banner-upgrade pass
  --include <csv>      Only process these top-level dirs
  --exclude <csv>      Skip these top-level dirs
  --help               Show this help
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

# ── sync-specific helpers ────────────────────────────────────────

keep_kind_to_variant_kind() {
  local kind="$1"
  case "$kind" in
    base) print -r -- "regular" ;;
    open-in-new-tab|locked|locked-b64|secure) print -r -- "$kind" ;;
    *) return 1 ;;
  esac
}

csv_contains() {
  local csv="$1"
  local needle="$2"
  local item
  for item in ${(s:,:)csv}; do
    item="$(trim "$item")"
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

derive_group_key_from_stem() {
  local stem="$1"
  local tail=""
  local base=""
  if is_eagler_name "$stem"; then
    tail="$(extract_eagler_tail "$stem")"
    print -r -- "eagler::${tail}"
    return
  fi
  base="$(derive_standard_base "$stem")"
  print -r -- "std::${base}"
}

variant_stem_for_group() {
  local key="$1"
  local kind="$2"
  local tail=""
  local base=""

  if [[ "$key" == eagler::* ]]; then
    tail="${key#eagler::}"
    case "$kind" in
      regular) print -r -- "eaglercraft-regular${tail}" ;;
      open-in-new-tab) print -r -- "eaglercraft-open-in-new-tab${tail}" ;;
      locked) print -r -- "eaglercraft-locked${tail}" ;;
      locked-b64) print -r -- "eaglercraft-locked-b64${tail}" ;;
      secure) print -r -- "eaglercraft-secure${tail}" ;;
      plain) print -r -- "eaglercraft${tail}" ;;
      label) print -r -- "eaglercraft${tail}" ;;
      *) return 1 ;;
    esac
    return
  fi

  base="${key#std::}"
  case "$kind" in
    regular) print -r -- "${base}-regular" ;;
    open-in-new-tab) print -r -- "${base}-open-in-new-tab" ;;
    locked) print -r -- "${base}-locked" ;;
    locked-b64) print -r -- "${base}-locked-b64" ;;
    secure) print -r -- "${base}-secure" ;;
    plain|label) print -r -- "$base" ;;
    *) return 1 ;;
  esac
}

variant_path_for_group() {
  local dir="$1"
  local key="$2"
  local kind="$3"
  print -r -- "$dir/$(variant_stem_for_group "$key" "$kind").html"
}

is_regular_stem_for_group() {
  local stem="$1"
  local key="$2"
  local kind
  local group
  kind="$(variant_kind_from_stem "$stem")"
  group="$(derive_group_key_from_stem "$stem")"
  [[ "$group" == "$key" && "$kind" == "regular" ]]
}

lock_generate() {
  local input="$1"
  local kind="$2"
  if [[ -n "$PASSWORD_OVERRIDE" ]]; then
    run_cmd "$LOCK_SCRIPT" "$input" "$PASSWORD_OVERRIDE" "$kind"
  else
    run_cmd "$LOCK_SCRIPT" "$input" "" "$kind"
  fi
}

maybe_upgrade_banner_file() {
  local file="$1"
  local stem kind

  has_banner_markup "$file" || return 0
  banner_has_latest_controls "$file" && return 0

  stem="${file:t:r}"
  kind="$(variant_kind_from_stem "$stem")"
  case "$kind" in
    open-in-new-tab|locked|locked-b64|secure)
      log "  upgrading banner controls in: ${file:t}"
      lock_generate "$file" "$kind"
      ;;
    *)
      warn "  banner detected in unsupported file type, skipping: ${file:t}"
      ;;
  esac
}

# ── Argument parsing ─────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || { err "--root requires a value"; exit 1; }
      ROOT_DIR="$2"
      shift 2
      ;;
    --keep)
      [[ $# -ge 2 ]] || { err "--keep requires a value"; exit 1; }
      KEEP_CSV="$2"
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
    --force)
      FORCE_REGENERATE="true"
      shift
      ;;
    --upgrade-banner)
      UPGRADE_BANNER="true"
      shift
      ;;
    --no-upgrade-banner)
      UPGRADE_BANNER="false"
      shift
      ;;
    --include)
      [[ $# -ge 2 ]] || { err "--include requires a value"; exit 1; }
      INCLUDE_DIRS="$2"
      shift 2
      ;;
    --exclude)
      [[ $# -ge 2 ]] || { err "--exclude requires a value"; exit 1; }
      EXCLUDE_DIRS="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

[[ -d "$ROOT_DIR" ]] || { err "Root directory not found: $ROOT_DIR"; exit 1; }
[[ -x "$LOCK_SCRIPT" ]] || { err "lock-game.sh is missing or not executable: $LOCK_SCRIPT"; exit 1; }

typeset -a KEEP_KINDS
typeset -A KEEP_SEEN
for raw in ${(s:,:)KEEP_CSV}; do
  norm="$(normalize_variant_kind "$raw")"
  if [[ -z "$norm" ]]; then
    err "Invalid keep kind: $raw"
    exit 1
  fi
  if [[ -z "${KEEP_SEEN[$norm]-}" ]]; then
    KEEP_KINDS+=("$norm")
    KEEP_SEEN[$norm]=1
  fi
done

if (( ${#KEEP_KINDS[@]} == 0 )); then
  err "Keep list cannot be empty"
  exit 1
fi

# ── Main loop ────────────────────────────────────────────────────

typeset -a TOP_DIRS
while IFS= read -r -d '' d; do
  TOP_DIRS+=("$d")
done < <(find "$ROOT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

for dir in "${TOP_DIRS[@]}"; do
  dir_name="${dir:t}"
  [[ "$dir_name" == .* ]] && continue
  if [[ -n "$INCLUDE_DIRS" ]] && ! csv_contains "$INCLUDE_DIRS" "$dir_name"; then
    continue
  fi
  if [[ -n "$EXCLUDE_DIRS" ]] && csv_contains "$EXCLUDE_DIRS" "$dir_name"; then
    continue
  fi

  typeset -a HTML_FILES
  HTML_FILES=()
  while IFS= read -r -d '' f; do
    HTML_FILES+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f -name '*.html' -print0 | sort -z)

  if (( ${#HTML_FILES[@]} == 0 )); then
    continue
  fi

  log "Processing folder: $dir_name"

  if [[ "$UPGRADE_BANNER" == "true" ]]; then
    for f in "${HTML_FILES[@]}"; do
      maybe_upgrade_banner_file "$f"
    done
    HTML_FILES=()
    while IFS= read -r -d '' f; do
      HTML_FILES+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f -name '*.html' -print0 | sort -z)
  fi

  typeset -A EAGLER_REG_GROUPS
  EAGLER_REG_GROUPS=()
  for local_file in "${HTML_FILES[@]}"; do
    stem="${local_file:t:r}"
    group_key="$(derive_group_key_from_stem "$stem")"
    kind="$(variant_kind_from_stem "$stem")"
    if [[ "$group_key" == eagler::* && "$group_key" != "eagler::" && "$kind" == "regular" ]]; then
      EAGLER_REG_GROUPS[$group_key]=1
    fi
  done

  primary_eagler_group=""
  if (( ${#EAGLER_REG_GROUPS[@]} == 1 )); then
    primary_eagler_group="${(@k)EAGLER_REG_GROUPS}"
  fi

  typeset -A GROUP_KEYS
  GROUP_KEYS=()
  local_file=""
  for local_file in "${HTML_FILES[@]}"; do
    stem="${local_file:t:r}"
    group_key="$(derive_group_key_from_stem "$stem")"
    if [[ "$group_key" == "eagler::" && -n "$primary_eagler_group" ]]; then
      group_key="$primary_eagler_group"
    fi
    if [[ "$group_key" == "std::" ]]; then
      warn "  skipping file with empty base name: ${local_file:t}"
      continue
    fi
    GROUP_KEYS[$group_key]=1
  done

  typeset -A KEEP_PATHS
  KEEP_PATHS=()

  for group_key in "${(@k)GROUP_KEYS}"; do
    label="$(variant_stem_for_group "$group_key" "label")"
    reg_path="$(variant_path_for_group "$dir" "$group_key" "regular")"
    open_path="$(variant_path_for_group "$dir" "$group_key" "open-in-new-tab")"
    locked_path="$(variant_path_for_group "$dir" "$group_key" "locked")"
    b64_path="$(variant_path_for_group "$dir" "$group_key" "locked-b64")"
    plain_path="$(variant_path_for_group "$dir" "$group_key" "plain")"

    existing_regular=""
    fallback=""
    for f in "${HTML_FILES[@]}"; do
      stem="${f:t:r}"
      fgroup="$(derive_group_key_from_stem "$stem")"
      if [[ "$fgroup" == "eagler::" && -n "$primary_eagler_group" ]]; then
        fgroup="$primary_eagler_group"
      fi
      [[ "$fgroup" == "$group_key" ]] || continue
      if [[ -z "$fallback" ]]; then
        fallback="$f"
      fi
      if is_regular_stem_for_group "$stem" "$group_key"; then
        existing_regular="$f"
        break
      fi
    done

    reg_expected="false"
    if [[ ! -f "$reg_path" ]]; then
      if [[ -n "$existing_regular" && "$existing_regular" != "$reg_path" ]]; then
        log "  base=$label: renaming regular source to protocol name"
        run_cmd mv "$existing_regular" "$reg_path"
        reg_expected="true"
      elif [[ -f "$plain_path" && "$plain_path" != "$reg_path" ]]; then
        log "  base=$label: promoting plain file to -regular"
        run_cmd mv "$plain_path" "$reg_path"
        reg_expected="true"
      elif [[ -f "$locked_path" ]]; then
        log "  base=$label: creating missing regular from locked"
        lock_generate "$locked_path" "base"
        reg_expected="true"
      elif [[ -f "$b64_path" ]]; then
        log "  base=$label: creating missing regular from locked-b64"
        lock_generate "$b64_path" "base"
        reg_expected="true"
      elif [[ -f "$open_path" ]]; then
        log "  base=$label: creating missing regular from open-in-new-tab"
        lock_generate "$open_path" "base"
        reg_expected="true"
      elif [[ -n "$fallback" ]]; then
        log "  base=$label: using fallback source to create regular"
        lock_generate "$fallback" "base"
        reg_expected="true"
      else
        warn "  base=$label: no source found, skipping"
        continue
      fi
    fi

    if [[ ! -f "$reg_path" && ! ( "$DRY_RUN" == "true" && "$reg_expected" == "true" ) ]]; then
      warn "  base=$label: regular source still missing after recovery"
      continue
    fi

    if [[ -f "$reg_path" ]]; then
      if has_trigger_comment "$reg_path"; then
        log "  base=$label: removing protocol trigger block from base"
        lock_generate "$reg_path" "base"
      fi
    elif [[ "$DRY_RUN" == "true" && "$reg_expected" == "true" ]]; then
      log "  base=$label: removing protocol trigger block from base"
      lock_generate "$reg_path" "base"
    fi

    for kind in "${KEEP_KINDS[@]}"; do
      out_kind="$(keep_kind_to_variant_kind "$kind")"
      out="$(variant_path_for_group "$dir" "$group_key" "$out_kind")"
      KEEP_PATHS[$out]=1
      if [[ "$kind" == "base" ]]; then
        continue
      fi
      if [[ -f "$out" && "$FORCE_REGENERATE" != "true" ]]; then
        continue
      fi
      log "  base=$label: generating $kind"
      lock_generate "$reg_path" "$out_kind"
    done
  done

  while IFS= read -r -d '' f; do
    if [[ -n "${KEEP_PATHS[$f]-}" ]]; then
      continue
    fi
    log "  removing extra file: ${f:t}"
    run_cmd rm -f "$f"
  done < <(find "$dir" -maxdepth 1 -type f -name '*.html' -print0)
done

log "Done."
