#!/bin/zsh
#
# common.sh
# Shared helper functions for lock-game protocol scripts.
# Source this file from lock-game.sh, sync-protocol-versions.sh,
# and create-folder-from-html.sh.
#
# Usage (from a sibling script):
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/common.sh"

# ── Guard against double-sourcing ────────────────────────────────
if [[ -n "${_LOCK_COMMON_LOADED:-}" ]]; then
  return 0
fi
_LOCK_COMMON_LOADED=1

# ── Dependency checks ────────────────────────────────────────────

check_dependencies() {
  if ! command -v perl >/dev/null 2>&1; then
    printf 'ERROR: perl is required but not found\n' >&2
    exit 1
  fi
  if ! command -v rg >/dev/null 2>&1; then
    printf 'NOTE: ripgrep (rg) not found; using perl fallback for pattern matching\n' >&2
  fi
}

# ── rg wrapper with perl fallback ────────────────────────────────
# Quiet grep: returns 0 if pattern matches anywhere in file, 1 otherwise.
# Uses ripgrep when available, falls back to perl (which handles the
# same regex syntax) when rg is not installed.

rg_q() {
  local pattern="$1"
  local file="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -q "$pattern" "$file"
  else
    RG_Q_PATTERN="$pattern" perl -ne \
      'if (/$ENV{RG_Q_PATTERN}/) { exit 0 } END { exit 1 }' "$file"
  fi
}

# ── String utilities ─────────────────────────────────────────────

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  print -r -- "$value"
}

to_bool() {
  local value
  value="$(trim "${(L)1}")"
  if [[ "$value" == "true" ]]; then
    print -r -- "true"
  else
    print -r -- "false"
  fi
}

# Normalize a variant kind string.
# Valid outputs: base | open-in-new-tab | locked | locked-b64
# Returns empty string for invalid input.
normalize_variant_kind() {
  local raw
  raw="$(trim "${(L)1}")"
  case "$raw" in
    base|open-in-new-tab|locked|locked-b64)
      print -r -- "$raw"
      ;;
    *)
      print -r -- ""
      ;;
  esac
}

# ── Eaglercraft naming helpers ───────────────────────────────────

is_eagler_name() {
  local lower="${(L)1}"
  [[ "$lower" == *eaglercraft* || "$lower" == *eaglrcraft* ]]
}

normalize_tail_suffix() {
  local raw="$1"
  raw="${raw#-}"
  raw="${raw#_}"
  raw="${raw# }"
  raw="${raw// /-}"
  raw="${raw//_/-}"
  raw="$(printf '%s' "$raw" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  if [[ -n "$raw" ]]; then
    print -r -- "-$raw"
  else
    print -r -- ""
  fi
}

extract_eagler_tail() {
  local stem_lower="${(L)1}"
  local rest=""
  local tail_src=""

  stem_lower="${stem_lower//eaglrcraft/eaglercraft}"
  if [[ "$stem_lower" != *eaglercraft* ]]; then
    print -r -- ""
    return
  fi

  rest="${stem_lower#*eaglercraft}"
  rest="${rest#-}"
  rest="${rest#_}"
  rest="${rest# }"

  case "$rest" in
    regular|open-in-new-tab|locked|locked-b64)
      tail_src=""
      ;;
    regular-*|regular_*|regular\ *)
      tail_src="${rest#regular}"
      ;;
    open-in-new-tab-*|open-in-new-tab_*|open-in-new-tab\ *)
      tail_src="${rest#open-in-new-tab}"
      ;;
    locked-b64-*|locked-b64_*|locked-b64\ *)
      tail_src="${rest#locked-b64}"
      ;;
    locked-*|locked_*|locked\ *)
      tail_src="${rest#locked}"
      ;;
    *)
      tail_src="$rest"
      ;;
  esac

  normalize_tail_suffix "$tail_src"
}

# ── Base name derivation ─────────────────────────────────────────

# Strip any variant suffix from a file stem to get the base name.
# "drive-mad-locked-b64" -> "drive-mad"
# "drive-mad-regular"    -> "drive-mad"
derive_standard_base() {
  local stem="$1"
  stem="${stem%-locked-b64}"
  stem="${stem%-locked}"
  stem="${stem%-open-in-new-tab}"
  stem="${stem%-regular}"
  stem="${stem%_regular}"
  stem="${stem% regular}"
  print -r -- "$stem"
}

# ── Variant naming ───────────────────────────────────────────────

# Given a raw file stem and a target kind, produce the protocol stem.
# kind: regular | open-in-new-tab | locked | locked-b64 | base
# "base" returns the bare name (no variant suffix).
variant_stem_from_raw() {
  local raw="$1"
  local kind="$2"
  local tail=""
  local base=""

  if is_eagler_name "$raw"; then
    tail="$(extract_eagler_tail "$raw")"
    case "$kind" in
      regular) print -r -- "eaglercraft-regular${tail}" ;;
      open-in-new-tab) print -r -- "eaglercraft-open-in-new-tab${tail}" ;;
      locked) print -r -- "eaglercraft-locked${tail}" ;;
      locked-b64) print -r -- "eaglercraft-locked-b64${tail}" ;;
      base) print -r -- "eaglercraft${tail}" ;;
      *) return 1 ;;
    esac
    return
  fi

  base="$(derive_standard_base "$raw")"
  case "$kind" in
    regular) print -r -- "${base}-regular" ;;
    open-in-new-tab) print -r -- "${base}-open-in-new-tab" ;;
    locked) print -r -- "${base}-locked" ;;
    locked-b64) print -r -- "${base}-locked-b64" ;;
    base) print -r -- "$base" ;;
    *) return 1 ;;
  esac
}

# Detect the variant kind from a file stem.
# Returns: regular | open-in-new-tab | locked | locked-b64 | plain
variant_kind_from_stem() {
  local stem="$1"
  local lower="${(L)stem}"
  local rest=""
  if is_eagler_name "$stem"; then
    lower="${lower//eaglrcraft/eaglercraft}"
    rest="${lower#*eaglercraft}"
    rest="${rest#-}"
    rest="${rest#_}"
    rest="${rest# }"
    case "$rest" in
      locked-b64|locked-b64-*|locked-b64_*|locked-b64\ *) print -r -- "locked-b64" ;;
      locked|locked-*|locked_*|locked\ *) print -r -- "locked" ;;
      open-in-new-tab|open-in-new-tab-*|open-in-new-tab_*|open-in-new-tab\ *) print -r -- "open-in-new-tab" ;;
      regular|regular-*|regular_*|regular\ *) print -r -- "regular" ;;
      *) print -r -- "plain" ;;
    esac
    return
  fi

  case "$stem" in
    *-locked-b64) print -r -- "locked-b64" ;;
    *-locked) print -r -- "locked" ;;
    *-open-in-new-tab) print -r -- "open-in-new-tab" ;;
    *-regular|*_regular|*" regular") print -r -- "regular" ;;
    *) print -r -- "plain" ;;
  esac
}

# ── Protocol detection ───────────────────────────────────────────

is_protocol_locked_b64() {
  rg_q 'var\s+LOCK_GAME_PROTOCOL_VERSION\s*=\s*"1"' "$1" &&
  rg_q 'var\s+LOCK_FILE_TYPE\s*=\s*"locked-b64"' "$1" &&
  rg_q 'var\s+REAL_PAGE_B64\s*=\s*"' "$1"
}

is_protocol_locked() {
  rg_q 'var\s+LOCK_GAME_PROTOCOL_VERSION\s*=\s*"1"' "$1" &&
  rg_q 'var\s+LOCK_FILE_TYPE\s*=\s*"locked"' "$1" &&
  rg_q 'var\s+REAL_PAGE\s*=\s*`' "$1"
}

has_banner_markup() {
  rg_q '<!--\s*LOCK-BANNER START\s*-->|id="secretBar"|__LOCK_BANNER_V4__' "$1"
}

banner_has_latest_controls() {
  rg_q '__LOCK_BANNER_V4__' "$1"
}

has_trigger_comment() {
  rg_q 'LOCK-GAME SETTINGS' "$1"
}
