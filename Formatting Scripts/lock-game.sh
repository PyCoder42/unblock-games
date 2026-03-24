#!/bin/zsh
#
# lock-game.sh
# Create or convert game lock wrappers using protocol naming:
# - <base>-regular.html
# - <base>-open-in-new-tab.html
# - <base>-locked.html
# - <base>-locked-b64.html
#
# Usage:
#   ./lock-game.sh <input-file.html> [password] [format]
#
# format:
#   base | open-in-new-tab | locked | locked-b64 | secure
#
# Trigger block (optional) in input:
#   <!-- LOCK-GAME SETTINGS
#   PASSWORD_ENABLED: true
#   SHOW_OPEN_IN_NEW_TAB_BANNER: true
#   GENERATE_OPEN_IN_NEW_TAB_VERSION: true
#   PASSWORD: supercoolpassword
#   OUTPUT_FORMAT: locked-b64
#   -->

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

check_dependencies

# ── Secure config reader ────────────────────────────────────────
SECURE_CONFIG="${SCRIPT_DIR:h}/.secure-config"

read_secure_config() {
  local key="$1"
  if [[ -f "$SECURE_CONFIG" ]]; then
    perl -ne "if (/^\\Q${key}\\E=(.+)/) { print \$1; exit }" "$SECURE_CONFIG"
  fi
}

INPUT="${1:-}"
CLI_PASSWORD="${2:-}"
CLI_FORMAT="${3:-}"
DEFAULT_PASSWORD="supercoolpassword"

if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
  echo "Usage: $0 <input-file.html> [password] [format]"
  echo ""
  echo "Formats: base | open-in-new-tab | locked | locked-b64 | secure"
  exit 1
fi

# ── lock-game–specific helpers ───────────────────────────────────

sanitize_comment_value() {
  local raw="$1"
  printf '%s' "$raw" | perl -pe 's/\r?\n/ /g; s/--/- -/g;'
}

extract_trigger_block() {
  perl -0777 -ne 'if (/<!--\s*LOCK-GAME SETTINGS(.*?)-->/s) { print $1 }' "$1"
}

extract_key_from_block() {
  local block="$1"
  local key="$2"
  local default_value="$3"
  local raw

  raw="$(printf '%s' "$block" | perl -ne "if (/^\\s*\\Q${key}\\E:\\s*(.*?)\\s*\$/i) { print \$1; exit }")"
  if [[ -z "$raw" ]]; then
    print -r -- "$default_value"
  else
    print -r -- "$(trim "$raw")"
  fi
}

extract_real_page_template() {
  perl -0777 -ne 'if (/var\s+REAL_PAGE\s*=\s*`(.*?)`\s*;/s) { print $1 }' "$1"
}

extract_real_page_b64() {
  perl -0777 -ne 'if (/var\s+REAL_PAGE_B64\s*=\s*"([A-Za-z0-9+\/=]+)"\s*;/s) { print $1 }' "$1"
}

extract_real_page_fallback_b64() {
  perl -0777 -ne 'if (/var\s+REAL_PAGE_B64_FALLBACK\s*=\s*"([A-Za-z0-9+\/=]+)"\s*;/s) { print $1 }' "$1"
}

extract_secure_inner_b64() {
  perl -0777 -ne 'if (/var\s+SECURE_INNER_B64\s*=\s*"([A-Za-z0-9+\/=]+)"\s*;/s) { print $1 }' "$1"
}

decode_b64_to_file() {
  local payload="$1"
  local outfile="$2"

  if printf '%s' "$payload" | base64 --decode > "$outfile" 2>/dev/null; then
    return
  fi

  # macOS fallback
  printf '%s' "$payload" | base64 -D > "$outfile"
}

escape_for_template_literal() {
  local infile="$1"
  local outfile="$2"
  perl -pe '
    s/\\/\\\\/g;
    s/`/\\`/g;
    s/\$\{/\\\${/g;
    s#</\s*script\s*>#<\\/script>#ig;
  ' "$infile" > "$outfile"
}

unescape_template_literal_to_file() {
  local infile="$1"
  local outfile="$2"
  perl -pe '
    s#<\\/script>#</script>#g;
    s/\\\$\{/\$\{/g;
    s/\\`/`/g;
    s/\\\\/\\/g;
  ' "$infile" > "$outfile"
}

remove_secret_bar() {
  local infile="$1"
  local outfile="$2"
  perl -0777 -pe '
    s/\s*<!--\s*LOCK-BANNER START\s*-->[\s\S]*?<!--\s*LOCK-BANNER END\s*-->\s*//g;
    s/\s*<div\s+id="secretBar"[^>]*>[\s\S]*?<\/div>\s*//g;
  ' "$infile" > "$outfile"
}

remove_trigger_block() {
  local infile="$1"
  local outfile="$2"
  perl -0777 -pe '
    s/\s*<!--\s*LOCK-GAME SETTINGS[\s\S]*?-->\s*//g;
  ' "$infile" > "$outfile"
}

# ── Detect input type ────────────────────────────────────────────

INPUT_TYPE="original"
if is_protocol_secure "$INPUT"; then
  INPUT_TYPE="secure"
elif is_protocol_locked_b64 "$INPUT"; then
  INPUT_TYPE="locked-b64"
elif is_protocol_locked "$INPUT"; then
  INPUT_TYPE="locked"
fi

DIR="$(dirname "$INPUT")"
BASE_RAW="$(basename "$INPUT" .html)"
BASE_CORE="$(variant_stem_from_raw "$BASE_RAW" "base")"
LOCKED_FILE="$DIR/$(variant_stem_from_raw "$BASE_RAW" "locked").html"
B64_FILE="$DIR/$(variant_stem_from_raw "$BASE_RAW" "locked-b64").html"
OPEN_TAB_FILE="$DIR/$(variant_stem_from_raw "$BASE_RAW" "open-in-new-tab").html"
REGULAR_FILE="$DIR/$(variant_stem_from_raw "$BASE_RAW" "regular").html"
SECURE_FILE="$DIR/$(variant_stem_from_raw "$BASE_RAW" "secure").html"

# ── Read settings ────────────────────────────────────────────────

SETTINGS_BLOCK="$(extract_trigger_block "$INPUT")"

PASSWORD_ENABLED="$(to_bool "$(extract_key_from_block "$SETTINGS_BLOCK" "PASSWORD_ENABLED" "true")")"
SHOW_BANNER="$(to_bool "$(extract_key_from_block "$SETTINGS_BLOCK" "SHOW_OPEN_IN_NEW_TAB_BANNER" "true")")"
GENERATE_OPEN_TAB_VERSION="$(to_bool "$(extract_key_from_block "$SETTINGS_BLOCK" "GENERATE_OPEN_IN_NEW_TAB_VERSION" "true")")"
FILE_OUTPUT_FORMAT="$(normalize_variant_kind "$(extract_key_from_block "$SETTINGS_BLOCK" "OUTPUT_FORMAT" "locked-b64")")"

if [[ -z "$FILE_OUTPUT_FORMAT" ]]; then
  FILE_OUTPUT_FORMAT="locked-b64"
fi

PASSWORD="$DEFAULT_PASSWORD"
if [[ -n "$CLI_PASSWORD" ]]; then
  PASSWORD="$CLI_PASSWORD"
fi

TARGET_FORMAT="$FILE_OUTPUT_FORMAT"
if [[ -n "$CLI_FORMAT" ]]; then
  TARGET_FORMAT="$(normalize_variant_kind "$CLI_FORMAT")"
  if [[ -z "$TARGET_FORMAT" ]]; then
    echo "Invalid format: $CLI_FORMAT"
    echo "Valid formats: base | open-in-new-tab | locked | locked-b64 | secure"
    exit 1
  fi
fi

# Enforce: password-protected files always show the banner.
if [[ "$PASSWORD_ENABLED" == "true" && "$SHOW_BANNER" == "false" ]]; then
  echo "NOTE: Forcing SHOW_OPEN_IN_NEW_TAB_BANNER to true (required when PASSWORD_ENABLED is true)"
  SHOW_BANNER="true"
fi

PASSWORD_COMMENT_SAFE="$(sanitize_comment_value "$PASSWORD")"
TARGET_FORMAT_COMMENT_SAFE="$(sanitize_comment_value "$TARGET_FORMAT")"

# ── Temporary files with safe cleanup ────────────────────────────

TMP_CLEAN="$(mktemp /tmp/lock-game-clean.XXXXXX)"
TMP_TEMPLATE_CONTENT="$(mktemp /tmp/lock-game-template-content.XXXXXX)"
TMP_ESCAPED="$(mktemp /tmp/lock-game-escaped.XXXXXX)"
TMP_PAYLOAD="$(mktemp /tmp/lock-game-payload.XXXXXX)"

lock_game_cleanup() {
  rm -f "$TMP_CLEAN" "$TMP_TEMPLATE_CONTENT" "$TMP_ESCAPED" "$TMP_PAYLOAD"
}
trap lock_game_cleanup EXIT

# ── Extract clean payload ────────────────────────────────────────

case "$INPUT_TYPE" in
  original)
    remove_secret_bar "$INPUT" "$TMP_CLEAN"
    ;;
  secure)
    SECURE_OUTER="$(extract_secure_inner_b64 "$INPUT")"
    if [[ -z "$SECURE_OUTER" ]]; then
      echo "Error: Could not extract SECURE_INNER_B64 from secure file: $INPUT"
      exit 1
    fi
    TMP_INNER_SEC="$(mktemp /tmp/lock-game-inner-sec.XXXXXX)"
    decode_b64_to_file "$SECURE_OUTER" "$TMP_INNER_SEC"
    PAYLOAD_B64_FROM_INNER="$(extract_real_page_b64 "$TMP_INNER_SEC")"
    rm -f "$TMP_INNER_SEC"
    if [[ -z "$PAYLOAD_B64_FROM_INNER" ]]; then
      echo "Error: Could not extract REAL_PAGE_B64 from inner content: $INPUT"
      exit 1
    fi
    decode_b64_to_file "$PAYLOAD_B64_FROM_INNER" "$TMP_CLEAN"
    ;;
  locked)
    FALLBACK_PAYLOAD_B64="$(extract_real_page_fallback_b64 "$INPUT")"
    if [[ -n "$FALLBACK_PAYLOAD_B64" ]]; then
      decode_b64_to_file "$FALLBACK_PAYLOAD_B64" "$TMP_CLEAN"
    else
      TEMPLATE_CONTENT="$(extract_real_page_template "$INPUT")"
      if [[ -z "$TEMPLATE_CONTENT" ]]; then
        echo "Error: Could not extract REAL_PAGE from protocol locked file: $INPUT"
        exit 1
      fi
      printf '%s' "$TEMPLATE_CONTENT" > "$TMP_TEMPLATE_CONTENT"
      unescape_template_literal_to_file "$TMP_TEMPLATE_CONTENT" "$TMP_CLEAN"
    fi
    ;;
  locked-b64)
    PAYLOAD_B64="$(extract_real_page_b64 "$INPUT")"
    if [[ -z "$PAYLOAD_B64" ]]; then
      echo "Error: Could not extract REAL_PAGE_B64 from protocol locked-b64 file: $INPUT"
      exit 1
    fi
    decode_b64_to_file "$PAYLOAD_B64" "$TMP_CLEAN"
    ;;
esac

remove_trigger_block "$TMP_CLEAN" "$TMP_PAYLOAD"
escape_for_template_literal "$TMP_PAYLOAD" "$TMP_ESCAPED"
PAYLOAD_B64="$(base64 < "$TMP_PAYLOAD" | tr -d '\n')"
PASSWORD_JS="$(printf '%s' "$PASSWORD" | perl -pe 's/\\/\\\\/g; s/"/\\"/g;')"

# ── Output writers ───────────────────────────────────────────────

write_regular() {
  local outfile="$1"
  cp "$TMP_PAYLOAD" "$outfile"
  echo "Created: $outfile"
}

render_banner_block() {
  cat <<'EOF_BANNER'
<!-- LOCK-BANNER START -->
<div id="secretBar"
     style="
        position: fixed;
        top: 0;
        left: 0;
        width: 100%;
        height: 48px;
        background: linear-gradient(90deg, #4e54c8, #8f94fb);
        color: white;
        font-family: Arial, sans-serif;
        font-size: 18px;
        display: flex;
        align-items: center;
        justify-content: center;
        box-shadow: 0 2px 6px rgba(0,0,0,0.3);
        z-index: 9999;
     ">
  <a href="#"
     onclick="return lockBannerOpenCurrent(event);"
     onmouseenter="lockBannerSetTextHover(this,true);"
     onmouseleave="lockBannerSetTextHover(this,false);"
     style="
        position: absolute;
        left: 0;
        top: 0;
        right: 168px;
        height: 100%;
        display: flex;
        align-items: center;
        justify-content: center;
        color: white;
        text-decoration: none;
        font-weight: bold;
        z-index: 2;
        transition: color 0.15s ease;
     ">
     Open in New Tab
  </a>
  <button type="button"
          title="Toggle Fullscreen"
          onclick="return lockBannerToggleFullscreen(event);"
          onmouseenter="lockBannerSetHover(this,true);"
          onmouseleave="lockBannerSetHover(this,false);"
          style="
             position: absolute;
             right: 112px;
             top: 0;
             width: 56px;
             height: 100%;
             display: flex;
             align-items: center;
             justify-content: center;
             font-size: 18px;
             font-weight: bold;
             color: white;
             border: none;
             background: transparent;
             cursor: pointer;
             z-index: 3;
             user-select: none;
             transition: color 0.15s ease, background-color 0.15s ease;
          ">
    &#x26F6;
  </button>
  <button type="button"
          title="Legacy Open in New Tab method (can fail in some small web code editors)."
          aria-label="Open in New Tab (legacy method)"
          onclick="return lockBannerOpenLegacy(event);"
          onmouseenter="lockBannerSetHover(this,true);"
          onmouseleave="lockBannerSetHover(this,false);"
          style="
             position: absolute;
             right: 56px;
             top: 0;
             width: 56px;
             height: 100%;
             display: flex;
             align-items: center;
             justify-content: center;
             font-size: 20px;
             font-weight: bold;
             color: white;
             border: none;
             background: transparent;
             cursor: pointer;
             z-index: 3;
             user-select: none;
             transition: color 0.15s ease, background-color 0.15s ease;
          ">
    <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>
  </button>
  <button type="button"
          title="Close Banner"
          onclick="return lockBannerRemove(event);"
          onmouseenter="lockBannerSetHover(this,true);"
          onmouseleave="lockBannerSetHover(this,false);"
          style="
             position: absolute;
             right: 0;
             top: 0;
             width: 56px;
             height: 100%;
             display: flex;
             align-items: center;
             justify-content: center;
             font-size: 22px;
             font-weight: bold;
             color: white;
             border: none;
             background: transparent;
             cursor: pointer;
             z-index: 3;
             user-select: none;
             transition: color 0.15s ease, background-color 0.15s ease;
          ">
    &times;
  </button>
</div>
<script>
(function() {
  if (window.__LOCK_BANNER_V4__) return;
  window.__LOCK_BANNER_V4__ = true;

  window.lockBannerSetTextHover = function(el, active) {
    if (!el) return false;
    el.style.color = active ? '#d8dcff' : 'white';
    el.style.backgroundColor = 'transparent';
    return false;
  };

  window.lockBannerSetHover = function(el, active) {
    if (!el) return false;
    el.style.color = active ? '#d8dcff' : 'white';
    el.style.backgroundColor = active ? 'rgba(255,255,255,0.12)' : 'transparent';
    return false;
  };

  window.lockBannerRemove = function(event) {
    if (event) {
      event.preventDefault();
      event.stopPropagation();
    }
    var secretBar = document.getElementById('secretBar');
    if (secretBar) secretBar.remove();
    var frame = document.getElementById('gameFrame');
    if (frame) { frame.style.top = '0'; frame.style.height = '100%'; }
    return false;
  };

  window.lockBannerOpenCurrent = function(event) {
    if (event) {
      event.preventDefault();
      event.stopPropagation();
    }
    var win = window.open('about:blank', '_blank');
    if (!win) return false;
    try { win.opener = null; } catch (err) {}
    if (win.focus) win.focus();

    var html;
    var gameFrame = document.getElementById('gameFrame');
    if (gameFrame && gameFrame.contentDocument) {
      html = gameFrame.contentDocument.documentElement.outerHTML;
    } else {
      html = document.documentElement.outerHTML;
      html = html.replace(
        /<!--\s*LOCK-BANNER START\s*-->[\s\S]*?<!--\s*LOCK-BANNER END\s*-->/i,
        ''
      );
    }

    win.document.open();
    win.document.write('<!DOCTYPE html>\n' + html);
    win.document.close();
    return false;
  };

  window.lockBannerOpenLegacy = function(event) {
    if (event) {
      event.preventDefault();
      event.stopPropagation();
    }
    var href = window.location.href;
    try {
      var currentUrl = new URL(window.location.href);
      var pathParts = currentUrl.pathname.split('/');
      var fileName = pathParts[pathParts.length - 1];
      if (!fileName && pathParts.length > 1) {
        fileName = pathParts[pathParts.length - 2];
      }
      if (fileName) {
        href = fileName + currentUrl.search + currentUrl.hash;
      }
    } catch (err) {}

    var link = document.createElement('a');
    link.href = href;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.style.display = 'none';
    document.body.appendChild(link);
    link.click();
    link.remove();
    return false;
  };

  window.lockBannerToggleFullscreen = function(event) {
    if (event) {
      event.preventDefault();
      event.stopPropagation();
    }
    if (document.fullscreenElement) {
      document.exitFullscreen().catch(function() {});
      return false;
    }
    var root = document.documentElement;
    var request =
      root.requestFullscreen ||
      root.webkitRequestFullscreen ||
      root.mozRequestFullScreen ||
      root.msRequestFullscreen;
    if (request) request.call(root);
    return false;
  };
})();
</script>
<!-- LOCK-BANNER END -->
EOF_BANNER
}

append_banner_block() {
  local outfile="$1"
  render_banner_block >> "$outfile"
}

write_locked() {
  local outfile="$1"

  cat > "$outfile" <<EOF_LOCKED
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Password Required</title>
<!-- LOCK-GAME SETTINGS
PASSWORD_ENABLED: $PASSWORD_ENABLED
SHOW_OPEN_IN_NEW_TAB_BANNER: $SHOW_BANNER
GENERATE_OPEN_IN_NEW_TAB_VERSION: $GENERATE_OPEN_TAB_VERSION
PASSWORD: $PASSWORD_COMMENT_SAFE
OUTPUT_FORMAT: $TARGET_FORMAT_COMMENT_SAFE
-->
<script>
// ========= LOCK SETTINGS (EDIT THESE) =========
var LOCK_GAME_PROTOCOL_VERSION = "1";
var LOCK_FILE_TYPE = "locked";
var PASSWORD = "$PASSWORD_JS";
var PASSWORD_ENABLED = $PASSWORD_ENABLED;
var SHOW_OPEN_IN_NEW_TAB_BANNER = $SHOW_BANNER;
// ===============================================
</script>
<style>
  body {
    margin: 0;
    height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #1a1a2e;
    font-family: Arial, sans-serif;
  }
  .password-box {
    background: #16213e;
    padding: 40px;
    border-radius: 12px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.4);
    text-align: center;
  }
  .password-box h2 {
    color: #e94560;
    margin-top: 0;
  }
  .password-box input {
    padding: 10px 16px;
    font-size: 16px;
    border: 2px solid #e94560;
    border-radius: 6px;
    background: #0f3460;
    color: white;
    outline: none;
    width: 220px;
  }
  .password-box button {
    padding: 10px 24px;
    font-size: 16px;
    border: none;
    border-radius: 6px;
    background: #e94560;
    color: white;
    cursor: pointer;
    margin-left: 8px;
  }
  .password-box button:hover { background: #c73652; }
  .error-msg { color: #e94560; margin-top: 12px; display: none; }
</style>
</head>
<body>
EOF_LOCKED

  if [[ "$SHOW_BANNER" == "true" ]]; then
    append_banner_block "$outfile"
  fi

  cat >> "$outfile" <<'EOF_LOCKED_BODY'
<div class="password-box" id="passwordScreen">
  <h2>Password Required</h2>
  <div>
    <input type="password" id="pwInput" placeholder="Enter password..." onkeydown="if(event.key==='Enter')checkPw()">
    <button onclick="checkPw()">Go</button>
  </div>
  <p class="error-msg" id="errorMsg">Wrong password. Try again.</p>
</div>
<script>
EOF_LOCKED_BODY

  cat >> "$outfile" <<EOF_LOCKED_PAYLOAD
var REAL_PAGE_B64_FALLBACK = "$PAYLOAD_B64";
var REAL_PAGE = \`
EOF_LOCKED_PAYLOAD

  cat "$TMP_ESCAPED" >> "$outfile"

  cat >> "$outfile" <<'EOF_LOCKED_FOOTER'
`;

function getGameHtml() {
  try { return atob(REAL_PAGE_B64_FALLBACK); } catch(e) {}
  return REAL_PAGE;
}

function removeBanner() {
  var bar = document.getElementById('secretBar');
  if (bar) bar.remove();
  var frame = document.getElementById('gameFrame');
  if (frame) { frame.style.top = '0'; frame.style.height = '100%'; }
}

function openRealPage() {
  var wasFullscreen = !!(document.fullscreenElement || document.webkitFullscreenElement);
  var html = getGameHtml();

  if (wasFullscreen && SHOW_OPEN_IN_NEW_TAB_BANNER) {
    // Fullscreen: load game in iframe to preserve fullscreen and keep banner
    var pwScreen = document.getElementById('passwordScreen');
    if (pwScreen) pwScreen.remove();
    document.body.style.cssText = 'margin:0;padding:0;overflow:hidden;height:100vh;background:#000;';
    document.documentElement.style.cssText = 'margin:0;padding:0;height:100%;';
    var oldStyles = document.head.querySelectorAll('style');
    for (var i = 0; i < oldStyles.length; i++) oldStyles[i].remove();

    var iframe = document.createElement('iframe');
    iframe.id = 'gameFrame';
    iframe.style.cssText = 'position:fixed;left:0;top:48px;width:100%;height:calc(100% - 48px);border:none;';
    iframe.setAttribute('allowfullscreen', '');
    document.body.appendChild(iframe);
    var iframeDoc = iframe.contentDocument || iframe.contentWindow.document;
    iframeDoc.open();
    iframeDoc.write(html);
    iframeDoc.close();
  } else {
    // Normal: replace entire document, remove banner
    removeBanner();
    document.open();
    document.write(html);
    document.close();
  }
}

function checkPw() {
  if (!PASSWORD_ENABLED) {
    openRealPage();
    return;
  }

  var input = document.getElementById('pwInput').value;
  if (input === PASSWORD) {
    openRealPage();
  } else {
    document.getElementById('errorMsg').style.display = 'block';
    document.getElementById('pwInput').value = '';
  }
}

if (!SHOW_OPEN_IN_NEW_TAB_BANNER) {
  removeBanner();
}

if (!PASSWORD_ENABLED) {
  var passwordScreen = document.getElementById('passwordScreen');
  if (passwordScreen) passwordScreen.style.display = 'none';
  openRealPage();
}
</script>
</body>
</html>
EOF_LOCKED_FOOTER

  echo "Created: $outfile"
}

write_locked_b64() {
  local outfile="$1"

  cat > "$outfile" <<EOF_B64
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Password Required</title>
<!-- LOCK-GAME SETTINGS
PASSWORD_ENABLED: $PASSWORD_ENABLED
SHOW_OPEN_IN_NEW_TAB_BANNER: $SHOW_BANNER
GENERATE_OPEN_IN_NEW_TAB_VERSION: $GENERATE_OPEN_TAB_VERSION
PASSWORD: $PASSWORD_COMMENT_SAFE
OUTPUT_FORMAT: $TARGET_FORMAT_COMMENT_SAFE
-->
<script>
// ========= LOCK SETTINGS (EDIT THESE) =========
var LOCK_GAME_PROTOCOL_VERSION = "1";
var LOCK_FILE_TYPE = "locked-b64";
var PASSWORD = "$PASSWORD_JS";
var PASSWORD_ENABLED = $PASSWORD_ENABLED;
var SHOW_OPEN_IN_NEW_TAB_BANNER = $SHOW_BANNER;
// ===============================================
</script>
<style>
  body {
    margin: 0;
    height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #1a1a2e;
    font-family: Arial, sans-serif;
  }
  .password-box {
    background: #16213e;
    padding: 40px;
    border-radius: 12px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.4);
    text-align: center;
  }
  .password-box h2 {
    color: #e94560;
    margin-top: 0;
  }
  .password-box input {
    padding: 10px 16px;
    font-size: 16px;
    border: 2px solid #e94560;
    border-radius: 6px;
    background: #0f3460;
    color: white;
    outline: none;
    width: 220px;
  }
  .password-box button {
    padding: 10px 24px;
    font-size: 16px;
    border: none;
    border-radius: 6px;
    background: #e94560;
    color: white;
    cursor: pointer;
    margin-left: 8px;
  }
  .password-box button:hover { background: #c73652; }
  .error-msg { color: #e94560; margin-top: 12px; display: none; }
</style>
</head>
<body>
EOF_B64

  if [[ "$SHOW_BANNER" == "true" ]]; then
    append_banner_block "$outfile"
  fi

  cat >> "$outfile" <<'EOF_B64_BODY'
<div class="password-box" id="passwordScreen">
  <h2>Password Required</h2>
  <div>
    <input type="password" id="pwInput" placeholder="Enter password..." onkeydown="if(event.key==='Enter')checkPw()">
    <button onclick="checkPw()">Go</button>
  </div>
  <p class="error-msg" id="errorMsg">Wrong password. Try again.</p>
</div>
<script>
EOF_B64_BODY

  cat >> "$outfile" <<EOF_B64_PAYLOAD
var REAL_PAGE_B64 = "$PAYLOAD_B64";
EOF_B64_PAYLOAD

  cat >> "$outfile" <<'EOF_B64_FOOTER'

function getGameHtml() { return atob(REAL_PAGE_B64); }

function removeBanner() {
  var bar = document.getElementById('secretBar');
  if (bar) bar.remove();
  var frame = document.getElementById('gameFrame');
  if (frame) { frame.style.top = '0'; frame.style.height = '100%'; }
}

function openRealPage() {
  var wasFullscreen = !!(document.fullscreenElement || document.webkitFullscreenElement);
  var html = getGameHtml();

  if (wasFullscreen && SHOW_OPEN_IN_NEW_TAB_BANNER) {
    // Fullscreen: load game in iframe to preserve fullscreen and keep banner
    var pwScreen = document.getElementById('passwordScreen');
    if (pwScreen) pwScreen.remove();
    document.body.style.cssText = 'margin:0;padding:0;overflow:hidden;height:100vh;background:#000;';
    document.documentElement.style.cssText = 'margin:0;padding:0;height:100%;';
    var oldStyles = document.head.querySelectorAll('style');
    for (var i = 0; i < oldStyles.length; i++) oldStyles[i].remove();

    var iframe = document.createElement('iframe');
    iframe.id = 'gameFrame';
    iframe.style.cssText = 'position:fixed;left:0;top:48px;width:100%;height:calc(100% - 48px);border:none;';
    iframe.setAttribute('allowfullscreen', '');
    document.body.appendChild(iframe);
    var iframeDoc = iframe.contentDocument || iframe.contentWindow.document;
    iframeDoc.open();
    iframeDoc.write(html);
    iframeDoc.close();
  } else {
    // Normal: replace entire document, remove banner
    removeBanner();
    document.open();
    document.write(html);
    document.close();
  }
}

function checkPw() {
  if (!PASSWORD_ENABLED) {
    openRealPage();
    return;
  }

  var input = document.getElementById('pwInput').value;
  if (input === PASSWORD) {
    openRealPage();
  } else {
    document.getElementById('errorMsg').style.display = 'block';
    document.getElementById('pwInput').value = '';
  }
}

if (!SHOW_OPEN_IN_NEW_TAB_BANNER) {
  removeBanner();
}

if (!PASSWORD_ENABLED) {
  var passwordScreen = document.getElementById('passwordScreen');
  if (passwordScreen) passwordScreen.style.display = 'none';
  openRealPage();
}
</script>
</body>
</html>
EOF_B64_FOOTER

  echo "Created: $outfile"
}

write_open_in_new_tab() {
  local outfile="$1"
  local tmp_banner
  tmp_banner="$(mktemp /tmp/lock-game-banner.XXXXXX)"

  render_banner_block > "$tmp_banner"

  BANNER_FILE="$tmp_banner" perl -0777 -pe '
    my $banner = do {
      local $/;
      open my $fh, "<", $ENV{BANNER_FILE} or die $!;
      <$fh>;
    };
    if (/<body\b[^>]*>/i) {
      s/(<body\b[^>]*>)/$1\n$banner/i;
    } else {
      $_ = $banner . "\n" . $_;
    }
  ' "$TMP_PAYLOAD" > "$outfile"

  rm -f "$tmp_banner"
  echo "Created: $outfile"
}

write_secure() {
  local outfile="$1"

  local jsdelivr_url unpkg_url
  jsdelivr_url="$(read_secure_config "JSDELIVR_URL")"
  unpkg_url="$(read_secure_config "UNPKG_URL")"

  # Read GITHUB_REPO early so we can derive the raw URL
  local github_repo
  github_repo="$(read_secure_config "GITHUB_REPO")"

  local github_raw_url
  github_raw_url="$(read_secure_config "GITHUB_RAW_URL")"
  if [[ -z "$github_raw_url" && -n "$github_repo" ]]; then
    github_raw_url="https://raw.githubusercontent.com/${github_repo}/main/config.json"
  fi

  if [[ -z "$jsdelivr_url" && -z "$github_repo" ]]; then
    echo "Error: .secure-config not found or missing JSDELIVR_URL/GITHUB_REPO."
    echo "Run setup-secure.sh first."
    exit 1
  fi

  # Derive GAME_ID from BASE_CORE (e.g., "drive-mad", "eaglercraft-1-12")
  local game_id="$BASE_CORE"

  # Escape URLs for JS embedding
  local jsdelivr_js github_raw_js unpkg_js game_id_js
  jsdelivr_js="$(printf '%s' "$jsdelivr_url" | perl -pe 's/\\/\\\\/g; s/"/\\"/g;')"
  github_raw_js="$(printf '%s' "$github_raw_url" | perl -pe 's/\\/\\\\/g; s/"/\\"/g;')"
  unpkg_js="$(printf '%s' "$unpkg_url" | perl -pe 's/\\/\\\\/g; s/"/\\"/g;')"
  game_id_js="$(printf '%s' "$game_id" | perl -pe 's/\\/\\\\/g; s/"/\\"/g;')"

  # Encrypt game HTML for CDN-hosted encrypted game data
  local game_data_dir game_data_path game_data_url game_key_hex game_key_js game_data_url_js
  game_data_dir="${SCRIPT_DIR:h}/game-data"
  mkdir -p "$game_data_dir"
  game_data_path="$game_data_dir/${game_id}.enc.json"

  if [[ -n "$github_repo" ]]; then
    game_data_url="https://cdn.jsdelivr.net/gh/${github_repo}@main/game-data/${game_id}.enc.json"
  else
    game_data_url=""
  fi

  game_key_hex="$(node "$SCRIPT_DIR/generate-enc-game-data.mjs" "$TMP_PAYLOAD" "$game_id" "$game_data_path")"
  if [[ -z "$game_key_hex" ]]; then
    echo "Error: Failed to encrypt game data for '$game_id'. Is Node.js installed?"
    exit 1
  fi
  game_key_js="$(printf '%s' "$game_key_hex" | perl -pe 's/\\/\\\\/g; s/"/\\"/g;')"
  game_data_url_js="$(printf '%s' "$game_data_url" | perl -pe 's/\\/\\\\/g; s/"/\\"/g;')"

  # Build the INNER HTML in a temp file
  local tmp_inner
  tmp_inner="$(mktemp /tmp/lock-game-secure-inner.XXXXXX)"

  cat > "$tmp_inner" <<EOF_SECURE_INNER_HEAD
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Loading...</title>
<style>
  body {
    margin: 0;
    height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #1a1a2e;
    font-family: Arial, sans-serif;
  }
  .password-box {
    background: #16213e;
    padding: 40px;
    border-radius: 12px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.4);
    text-align: center;
  }
  .password-box h2 {
    color: #e94560;
    margin-top: 0;
  }
  .password-box input {
    padding: 10px 16px;
    font-size: 16px;
    border: 2px solid #e94560;
    border-radius: 6px;
    background: #0f3460;
    color: white;
    outline: none;
    width: 220px;
  }
  .password-box button {
    padding: 10px 24px;
    font-size: 16px;
    border: none;
    border-radius: 6px;
    background: #e94560;
    color: white;
    cursor: pointer;
    margin-left: 8px;
  }
  .password-box button:hover { background: #c73652; }
  .error-msg { color: #e94560; margin-top: 12px; display: none; }
  .loading-msg { color: #8f94fb; font-size: 18px; }
</style>
</head>
<body>
EOF_SECURE_INNER_HEAD

  # Append banner block INSIDE the inner HTML
  if [[ "$SHOW_BANNER" == "true" ]]; then
    append_banner_block "$tmp_inner"
  fi

  cat >> "$tmp_inner" <<'EOF_SECURE_INNER_BODY'
<div id="loadingScreen" class="password-box">
  <p class="loading-msg">Loading...</p>
</div>
<div class="password-box" id="passwordScreen" style="display:none;">
  <h2>Password Required</h2>
  <div>
    <input type="password" id="pwInput" placeholder="Enter password..." onkeydown="if(event.key==='Enter')checkPw()">
    <button onclick="checkPw()">Go</button>
  </div>
  <p class="error-msg" id="errorMsg">Wrong password. Try again.</p>
</div>
<script>
EOF_SECURE_INNER_BODY

  # Write JS config variables
  cat >> "$tmp_inner" <<EOF_SECURE_INNER_CONFIG
var GAME_ID = "$game_id_js";
var JSDELIVR_URL = "$jsdelivr_js";
var GITHUB_RAW_URL = "$github_raw_js";
var UNPKG_URL = "$unpkg_js";
var SHOW_OPEN_IN_NEW_TAB_BANNER = $SHOW_BANNER;
var GAME_KEY = "$game_key_js";
var GAME_DATA_URL = "$game_data_url_js";
EOF_SECURE_INNER_CONFIG

  # Write all the JS logic
  cat >> "$tmp_inner" <<'EOF_SECURE_INNER_JS'

var remotePasswords = [];
var clientIps = [];
var clientIpPromise = detectClientIps();

function _hexToBytes(hex) {
  var arr = new Uint8Array(hex.length / 2);
  for (var i = 0; i < arr.length; i++) arr[i] = parseInt(hex.substr(i * 2, 2), 16);
  return arr;
}
function _b64ToBytes(b64) {
  var bin = atob(b64);
  var arr = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
  return arr;
}
function fetchAndDecryptGame() {
  return fetch(GAME_DATA_URL)
    .then(function(resp) { return resp.json(); })
    .then(function(enc) {
      var keyBytes = _hexToBytes(GAME_KEY);
      return crypto.subtle.importKey('raw', keyBytes, {name: 'AES-GCM'}, false, ['decrypt'])
        .then(function(key) {
          var iv = _hexToBytes(enc.iv);
          var ct = _b64ToBytes(enc.ciphertext);
          var tag = _hexToBytes(enc.authTag);
          var combined = new Uint8Array(ct.length + tag.length);
          combined.set(ct);
          combined.set(tag, ct.length);
          return crypto.subtle.decrypt({name: 'AES-GCM', iv: iv}, key, combined);
        })
        .then(function(decrypted) { return new TextDecoder().decode(decrypted); });
    });
}
function loadAndRunGame() {
  return fetchAndDecryptGame().then(function(html) { openRealPage(html); });
}

function trimString(value) {
  return String(value == null ? '' : value).replace(/^\s+|\s+$/g, '');
}

function normalizeGameId(value) {
  var normalized = trimString(value).toLowerCase();
  if (!normalized) return '';

  normalized = normalized.replace(/\.html$/i, '');
  normalized = normalized.replace(/eaglrcraft/g, 'eaglercraft');
  normalized = normalized.replace(/open[-\s]*in[-\s]*new[-\s]*tab/g, ' ');
  normalized = normalized.replace(/locked[-\s]*b64/g, ' ');
  normalized = normalized.replace(/\b(secure|regular|locked)\b/g, ' ');
  normalized = normalized.replace(/[._]+/g, ' ');
  normalized = normalized.replace(/[^a-z0-9]+/g, '-');
  normalized = normalized.replace(/-+/g, '-').replace(/^-+|-+$/g, '');
  return normalized;
}

function escapeHtmlText(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function uniquePush(list, value) {
  var normalized = trimString(value);
  if (!normalized || list.indexOf(normalized) !== -1) return;
  list.push(normalized);
}

function extractIps(text, list) {
  if (!text) return;

  text.replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, function(ip) {
    if (isUsableAllowedIp(ip)) uniquePush(list, ip);
    return ip;
  });

  text.replace(/\b(?:[A-F0-9]{1,4}:){2,}[A-F0-9:]{1,4}\b/ig, function(ip) {
    if ((ip.indexOf('::') === -1 || ip.length > 2) && isUsableAllowedIp(ip)) uniquePush(list, ip);
    return ip;
  });
}

function isPlaceholderIp(ip) {
  var normalized = trimString(ip).toLowerCase();
  return normalized === '0.0.0.0' ||
    normalized === '::' ||
    normalized === '0:0:0:0:0:0:0:0' ||
    normalized === '::ffff:0.0.0.0';
}

function isLoopbackIp(ip) {
  var normalized = trimString(ip).toLowerCase();
  return /^127\./.test(normalized) ||
    normalized === '::1' ||
    normalized === '0:0:0:0:0:0:0:1' ||
    normalized === 'localhost';
}

function isPrivateIpv4(ip) {
  return /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)/.test(ip);
}

function isValidIpv4(ip) {
  var normalized = trimString(ip);
  if (!/^(?:\d{1,3}\.){3}\d{1,3}$/.test(normalized)) return false;

  return normalized.split('.').every(function(part) {
    var numeric = Number(part);
    return numeric >= 0 && numeric <= 255;
  });
}

function isPublicIpv4(ip) {
  return isValidIpv4(ip) &&
    !isPlaceholderIp(ip) &&
    !isLoopbackIp(ip) &&
    !/^169\.254\./.test(ip) &&
    !isPrivateIpv4(ip);
}

function isLikelyIpv6(ip) {
  var normalized = trimString(ip).toLowerCase();
  var parts;
  var nonEmpty = 0;
  var i;

  if (normalized.indexOf(':') === -1) return false;
  if (!/^[0-9a-f:]+$/.test(normalized)) return false;
  if (normalized.indexOf(':::') !== -1) return false;

  parts = normalized.split(':');
  for (i = 0; i < parts.length; i++) {
    if (!parts[i]) continue;
    if (parts[i].length > 4) return false;
    nonEmpty++;
  }

  if (normalized.indexOf('::') === -1) {
    return parts.length === 8 && nonEmpty === 8;
  }
  return parts.length <= 8 && nonEmpty > 0;
}

function isUsableAllowedIp(ip) {
  var normalized = trimString(ip);
  if (!normalized) return false;
  if (isPlaceholderIp(normalized) || isLoopbackIp(normalized)) return false;
  return isValidIpv4(normalized) || isLikelyIpv6(normalized);
}

function scoreIp(ip) {
  if (isPrivateIpv4(ip)) return 0;
  if (isPublicIpv4(ip)) return 1;
  if (isLikelyIpv6(ip) && !isPlaceholderIp(ip) && !isLoopbackIp(ip)) return 2;
  if (isPlaceholderIp(ip) || isLoopbackIp(ip)) return 9;
  return 8;
}

function sortIps(list) {
  return list.slice().sort(function(a, b) {
    var diff = scoreIp(a) - scoreIp(b);
    if (diff !== 0) return diff;
    return a < b ? -1 : a > b ? 1 : 0;
  });
}

function detectViaWebRtc(list, done) {
  var RTCPeer = window.RTCPeerConnection || window.webkitRTCPeerConnection || window.mozRTCPeerConnection;
  if (!RTCPeer) {
    done();
    return;
  }

  var finished = false;
  var pc;

  function finish() {
    if (finished) return;
    finished = true;
    try { if (pc) pc.close(); } catch (error) {}
    done();
  }

  try {
    pc = new RTCPeer({ iceServers: [] });
    if (pc.createDataChannel) pc.createDataChannel('');
    pc.onicecandidate = function(event) {
      if (!event || !event.candidate) {
        finish();
        return;
      }
      extractIps(event.candidate.candidate || '', list);
    };
    pc.createOffer()
      .then(function(offer) {
        extractIps(offer && offer.sdp || '', list);
        return pc.setLocalDescription(offer);
      })
      .then(function() {
        extractIps(pc.localDescription && pc.localDescription.sdp || '', list);
      })
      .catch(function() {
        finish();
      });
  } catch (error) {
    finish();
    return;
  }

  setTimeout(finish, 1800);
}

function detectViaPublicLookup(list, done) {
  if (!window.fetch) {
    done();
    return;
  }

  var finished = false;
  function finish() {
    if (finished) return;
    finished = true;
    done();
  }

  fetch('https://api.ipify.org?format=json', { cache: 'no-store' })
    .then(function(response) { return response.ok ? response.json() : null; })
    .then(function(payload) {
      if (payload && payload.ip) uniquePush(list, payload.ip);
    })
    .catch(function() {})
    .then(finish);

  setTimeout(finish, 1800);
}

function detectClientIps() {
  return new Promise(function(resolve) {
    var collected = [];
    var pending = 2;
    var resolved = false;

    function finishOne() {
      pending--;
      if (pending > 0 || resolved) return;
      resolved = true;
      clientIps = sortIps(collected);
      resolve(clientIps);
    }

    detectViaWebRtc(collected, finishOne);
    detectViaPublicLookup(collected, finishOne);

    setTimeout(function() {
      if (resolved) return;
      resolved = true;
      clientIps = sortIps(collected);
      resolve(clientIps);
    }, 2600);
  });
}

function primaryCurrentIp() {
  var sorted = sortIps(clientIps).filter(function(ip) {
    return isUsableAllowedIp(ip) && scoreIp(ip) < 8;
  });
  if (sorted.length) return sorted[0];
  return clientIps.length ? clientIps[0] : 'Unavailable';
}

function normalizePasswordList(rawConfig) {
  var source = rawConfig && typeof rawConfig === 'object' ? rawConfig : {};
  var output = [];

  function addPassword(value) {
    var normalized = trimString(value);
    if (!normalized || output.indexOf(normalized) !== -1) return;
    output.push(normalized);
  }

  addPassword(source.password);
  if (Array.isArray(source.passwords)) {
    source.passwords.forEach(addPassword);
  }

  return output;
}

function normalizeBlockedMap(rawBlocked) {
  var output = {};
  var blocked = rawBlocked && typeof rawBlocked === 'object' ? rawBlocked : {};

  Object.keys(blocked).forEach(function(key) {
    var normalizedKey = normalizeGameId(key);
    var value = blocked[key];
    if (!normalizedKey) return;
    if (value === true) {
      output[normalizedKey] = true;
    } else if (typeof value === 'string' && trimString(value)) {
      output[normalizedKey] = trimString(value);
    }
  });

  return output;
}

function normalizeAllowedIps(rawAllowedIps) {
  var output = {};
  var i;

  function addIpValue(ipValue, labelValue) {
    String(ipValue == null ? '' : ipValue).split(',').forEach(function(candidate) {
      var normalizedIp = trimString(candidate);
      if (!isUsableAllowedIp(normalizedIp)) return;
      output[normalizedIp] = { label: trimString(labelValue) };
    });
  }

  if (!rawAllowedIps) return output;

  if (Array.isArray(rawAllowedIps)) {
    for (i = 0; i < rawAllowedIps.length; i++) {
      var entry = rawAllowedIps[i];
      if (typeof entry === 'string') {
        entry = { ip: entry, label: '' };
      }
      if (entry && (entry.ip || entry.address)) {
        addIpValue(entry.ip || entry.address, entry.label);
      }
    }
  } else {
    Object.keys(rawAllowedIps).forEach(function(ip) {
      var normalizedIp = trimString(ip);
      if (!normalizedIp) return;
      var value = rawAllowedIps[ip];
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        addIpValue(normalizedIp, value.label);
      } else {
        addIpValue(normalizedIp, value);
      }
    });
  }

  return output;
}

function normalizeConfig(rawConfig) {
  var source = rawConfig && typeof rawConfig === 'object' ? rawConfig : {};
  var blocked = normalizeBlockedMap(source.blocked);
  var games = {};
  var passwords = normalizePasswordList(source);

  (Array.isArray(source.games) ? source.games : []).forEach(function(gameId) {
    var normalizedGameId = normalizeGameId(gameId);
    if (normalizedGameId) games[normalizedGameId] = true;
  });

  Object.keys(blocked).forEach(function(gameId) {
    games[gameId] = true;
  });

  return {
    password: passwords[0] || '',
    passwords: passwords,
    blocked: blocked,
    games: Object.keys(games).sort(),
    allowedIps: normalizeAllowedIps(source.allowedIps || source.allowedIPs || source.allowedIpAddresses),
  };
}


function normalizeAllowedIpMap(config) {
  var output = {};
  var normalizedAllowedIps = normalizeAllowedIps(config && (config.allowedIps || config.allowedIPs || config.allowedIpAddresses));

  Object.keys(normalizedAllowedIps).forEach(function(ip) {
    output[trimString(ip)] = true;
  });
  return output;
}

function isAllowedIp(config) {
  var allowedIpMap = normalizeAllowedIpMap(config);
  var usableClientIps = sortIps(clientIps).filter(function(ip) {
    return isUsableAllowedIp(ip);
  });
  var i;

  for (i = 0; i < usableClientIps.length; i++) {
    if (allowedIpMap[usableClientIps[i]]) return true;
  }
  return false;
}

function removeBanner() {
  var bar = document.getElementById('secretBar');
  if (bar) bar.remove();
  var frame = document.getElementById('gameFrame');
  if (frame) { frame.style.top = '0'; frame.style.height = '100%'; }
}

function openRealPage(html) {
  var wasFullscreen = !!(document.fullscreenElement || document.webkitFullscreenElement);

  if (wasFullscreen && SHOW_OPEN_IN_NEW_TAB_BANNER) {
    var pwScreen = document.getElementById('passwordScreen');
    if (pwScreen) pwScreen.remove();
    var loadScreen = document.getElementById('loadingScreen');
    if (loadScreen) loadScreen.remove();
    document.body.style.cssText = 'margin:0;padding:0;overflow:hidden;height:100vh;background:#000;';
    document.documentElement.style.cssText = 'margin:0;padding:0;height:100%;';
    var oldStyles = document.head.querySelectorAll('style');
    for (var i = 0; i < oldStyles.length; i++) oldStyles[i].remove();

    var iframe = document.createElement('iframe');
    iframe.id = 'gameFrame';
    iframe.style.cssText = 'position:fixed;left:0;top:48px;width:100%;height:calc(100% - 48px);border:none;';
    iframe.setAttribute('allowfullscreen', '');
    document.body.appendChild(iframe);
    var iframeDoc = iframe.contentDocument || iframe.contentWindow.document;
    iframeDoc.open();
    iframeDoc.write(html);
    iframeDoc.close();
  } else {
    removeBanner();
    document.open();
    document.write(html);
    document.close();
  }
}

function checkPw() {
  var input = document.getElementById('pwInput').value;
  if (remotePasswords.indexOf(input) !== -1) {
    var pwBtn = document.querySelector('#passwordScreen button');
    var pwField = document.getElementById('pwInput');
    var errMsg = document.getElementById('errorMsg');
    if (pwBtn) pwBtn.disabled = true;
    if (pwField) pwField.disabled = true;
    if (errMsg) errMsg.style.display = 'none';
    loadAndRunGame().catch(function() {
      if (errMsg) { errMsg.textContent = 'Failed to load game data. Check your connection.'; errMsg.style.display = 'block'; }
      if (pwBtn) pwBtn.disabled = false;
      if (pwField) { pwField.disabled = false; pwField.value = ''; }
    });
  } else {
    document.getElementById('errorMsg').style.display = 'block';
    document.getElementById('pwInput').value = '';
  }
}

function showPasswordPrompt() {
  var loadScreen = document.getElementById('loadingScreen');
  if (loadScreen) loadScreen.style.display = 'none';
  var pwScreen = document.getElementById('passwordScreen');
  if (pwScreen) pwScreen.style.display = '';
  var pwInput = document.getElementById('pwInput');
  if (pwInput) pwInput.focus();
}

function showBlocked() {
  // Fake Chrome "This site can't be reached" error page
  var currentIp = primaryCurrentIp();
  var copyValueJs = JSON.stringify(currentIp);
  document.open();
  document.write('<!DOCTYPE html><html><head><meta charset="UTF-8">' +
    '<title>' + location.hostname + '</title>' +
    '<style>' +
    'body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;' +
    'background:#fff;color:#333;margin:0;padding:40px 40px 20px;line-height:1.6;}' +
    '.icon{width:48px;height:48px;margin-bottom:16px;opacity:0.3;}' +
    'h1{font-size:20px;font-weight:normal;color:#333;margin:0 0 6px;}' +
    '.desc{font-size:14px;color:#646464;margin:0 0 16px;}' +
    '.error-code{font-size:12px;color:#999;margin:24px 0 16px;}' +
    '.suggestions{font-size:14px;color:#646464;margin-top:24px;}' +
    '.suggestions ul{padding-left:20px;margin:8px 0;}' +
    '.suggestions li{margin:4px 0;}' +
    '.ip-box{margin-top:20px;padding:12px 14px;border-radius:8px;background:#f6f8fc;border:1px solid #d6def3;max-width:520px;}' +
    '.ip-title{display:block;font-size:12px;font-weight:600;letter-spacing:.04em;color:#5f6368;text-transform:uppercase;margin-bottom:6px;}' +
    '.ip-value{font-size:15px;color:#202124;word-break:break-all;}' +
    '.ip-actions{margin-top:10px;display:flex;align-items:center;gap:10px;}' +
    '.copy-btn{display:inline-block;background:#4285f4;color:#fff;padding:8px 16px;border-radius:4px;font-size:14px;cursor:pointer;border:none;}' +
    '.copy-btn:hover{background:#3367d6;}' +
    '.copy-status{font-size:13px;color:#5f6368;}' +
    'a{color:#4285f4;text-decoration:none;}' +
    'a:hover{text-decoration:underline;}' +
    '.btn{display:inline-block;background:#4285f4;color:#fff;padding:8px 24px;' +
    'border-radius:4px;font-size:14px;margin-top:16px;cursor:pointer;border:none;}' +
    '.btn:hover{background:#3367d6;}' +
    '</style></head><body>' +
    '<svg class="icon" viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg">' +
    '<circle cx="24" cy="24" r="22" fill="none" stroke="#999" stroke-width="2"/>' +
    '<path d="M24 14v14M24 34v2" stroke="#999" stroke-width="3" stroke-linecap="round"/>' +
    '</svg>' +
    '<h1>This site can\u2019t be reached</h1>' +
    '<p class="desc">The connection was reset.</p>' +
    '<p class="desc">Try:</p>' +
    '<div class="suggestions"><ul>' +
    '<li>Checking the connection</li>' +
    '<li>Checking the proxy and the firewall</li>' +
    '<li>Running Network Diagnostics</li>' +
    '</ul></div>' +
    '<div class="ip-box">' +
    '<span class="ip-title">Current IP</span>' +
    '<span class="ip-value">' + escapeHtmlText(currentIp) + '</span>' +
    '<div class="ip-actions">' +
    '<button class="copy-btn" onclick="return copyCurrentIp()">Copy IP</button>' +
    '<span class="copy-status" id="copyStatus"></span>' +
    '</div>' +
    '</div>' +
    '<p class="error-code">ERR_CONNECTION_RESET</p>' +
    '<script>' +
    'function copyCurrentIp(){' +
      'var value=' + copyValueJs + ';' +
      'var status=document.getElementById("copyStatus");' +
      'if(!value||value==="Unavailable"){if(status)status.textContent="Unavailable";return false;}' +
      'function fallback(){window.prompt("Copy IP", value);if(status)status.textContent="Copy manually";}' +
      'if(navigator.clipboard&&navigator.clipboard.writeText){' +
        'navigator.clipboard.writeText(value).then(function(){if(status)status.textContent="Copied";}).catch(fallback);' +
      '}else{fallback();}' +
      'return false;' +
    '}' +
    '</scr' + 'ipt>' +
    '</body></html>');
  document.close();
}

function processConfig(config) {
  var normalizedConfig = normalizeConfig(config);
  var blockVal = normalizedConfig.blocked && normalizedConfig.blocked[GAME_ID];
  var isBlocked = blockVal === true || (typeof blockVal === 'string' && new Date(blockVal) > new Date());
  if (isBlocked && !isAllowedIp(normalizedConfig)) { showBlocked(); return; }
  remotePasswords = normalizedConfig.passwords || [];
  if (!remotePasswords.length) {
    // No password set — load game directly
    loadAndRunGame();
    return;
  }
  showPasswordPrompt();
}

function compareJsdelivrVersions(left, right) {
  var leftParts = trimString(left).split('.');
  var rightParts = trimString(right).split('.');
  var length = Math.max(leftParts.length, rightParts.length);
  var i;

  for (i = 0; i < length; i++) {
    var leftValue = Number(leftParts[i] || 0);
    var rightValue = Number(rightParts[i] || 0);
    if (leftValue !== rightValue) return leftValue - rightValue;
  }

  return trimString(left) < trimString(right) ? -1 : trimString(left) > trimString(right) ? 1 : 0;
}

function parseJsdelivrUrlInfo(url) {
  var cleaned = trimString(url).replace(/[?#].*$/, '');
  var match = cleaned.match(/^https:\/\/cdn\.jsdelivr\.net\/gh\/([^@/]+\/[^@/]+)@([^/]+)\/(.+)$/i);

  if (!match) {
    return {
      repo: '',
      version: '',
      filePath: '',
      url: cleaned,
    };
  }

  return {
    repo: trimString(match[1]),
    version: trimString(match[2]),
    filePath: trimString(match[3]),
    url: cleaned,
  };
}

function buildJsdelivrVersionUrl(infoOrUrl, version) {
  var info = typeof infoOrUrl === 'string' ? parseJsdelivrUrlInfo(infoOrUrl) : (infoOrUrl || {});
  var repo = trimString(info.repo);
  var filePath = trimString(info.filePath);
  var normalizedVersion = trimString(version);

  if (!repo || !filePath || !normalizedVersion) return '';
  return 'https://cdn.jsdelivr.net/gh/' + repo + '@' + normalizedVersion + '/' + filePath;
}

function getJsdelivrStorage() {
  try {
    if (typeof window !== 'undefined' && window.localStorage) return window.localStorage;
  } catch (error) {}
  try {
    if (typeof localStorage !== 'undefined') return localStorage;
  } catch (error) {}
  return null;
}

function getCachedJsdelivrVersion() {
  var storage = getJsdelivrStorage();
  if (!storage || !storage.getItem) return '';
  try {
    return trimString(storage.getItem('unblockGamesJsdelivrVersion'));
  } catch (error) {
    return '';
  }
}

function rememberJsdelivrVersion(version) {
  var storage = getJsdelivrStorage();
  var normalizedVersion = trimString(version);
  if (!storage || !storage.setItem || !normalizedVersion) return;
  try {
    storage.setItem('unblockGamesJsdelivrVersion', normalizedVersion);
  } catch (error) {}
}

function fetchJsdelivrConfig(readUrl) {
  return fetch(readUrl + '?t=' + Date.now(), {
    headers: { Accept: 'application/json' },
  })
    .then(function(response) {
      if (!response.ok) throw new Error(response.status);
      return response.json();
    })
    .then(function(config) {
      var info = parseJsdelivrUrlInfo(readUrl);
      if (info.version) rememberJsdelivrVersion(info.version);
      return { ok: true, source: 'jsdelivr', config: config, url: readUrl };
    });
}

function resolveJsdelivrReadUrls() {
  var normalizedUrl = trimString(JSDELIVR_URL);
  var info = parseJsdelivrUrlInfo(normalizedUrl);
  var candidates = normalizedUrl ? [normalizedUrl] : [];
  var exactVersions = [];
  var cachedVersion = getCachedJsdelivrVersion();

  if (!normalizedUrl) return Promise.resolve([]);
  if (cachedVersion) exactVersions.push(cachedVersion);
  if (!window.fetch || !info.repo || !info.filePath) {
    return Promise.resolve(exactVersions.map(function(version) {
      return buildJsdelivrVersionUrl(info, version);
    }).concat(candidates).filter(function(value, index, list) {
      return value && list.indexOf(value) === index;
    }));
  }

  return fetch('https://data.jsdelivr.com/v1/package/gh/' + info.repo + '?t=' + Date.now(), {
    headers: { Accept: 'application/json' },
  })
    .then(function(response) {
      if (!response.ok) throw new Error('metadata failed');
      return response.json();
    })
    .then(function(payload) {
      var versions = Array.isArray(payload && payload.versions) ? payload.versions.slice().sort(compareJsdelivrVersions) : [];
      var latestVersion = versions.length ? trimString(versions[versions.length - 1]) : '';
      if (latestVersion) exactVersions.push(latestVersion);
      return exactVersions
        .filter(function(value, index) {
          return value && exactVersions.indexOf(value) === index;
        })
        .sort(compareJsdelivrVersions)
        .reverse()
        .map(function(version) {
          return buildJsdelivrVersionUrl(info, version);
        })
        .concat(candidates)
        .filter(function(value, index, list) {
          return value && list.indexOf(value) === index;
        });
    })
    .catch(function() {
      return exactVersions
        .filter(function(value, index) {
          return value && exactVersions.indexOf(value) === index;
        })
        .sort(compareJsdelivrVersions)
        .reverse()
        .map(function(version) {
          return buildJsdelivrVersionUrl(info, version);
        })
        .concat(candidates)
        .filter(function(value, index, list) {
          return value && list.indexOf(value) === index;
        });
    });
}

function readJsdelivrConfigFromUrl(readUrl) {
  return fetchJsdelivrConfig(readUrl).catch(function() {
    return { ok: false, source: 'jsdelivr', url: readUrl };
  });
}

function readJsdelivrConfig() {
  if (!JSDELIVR_URL) return Promise.resolve({ ok: false, source: 'jsdelivr' });

  return resolveJsdelivrReadUrls().then(function(readUrls) {
    var index = 0;

    function tryNext() {
      if (index >= readUrls.length) return Promise.resolve({ ok: false, source: 'jsdelivr' });

      return readJsdelivrConfigFromUrl(readUrls[index++]).then(function(result) {
        if (result.ok) return result;
        return tryNext();
      });
    }
    return tryNext();
  });
}

function readGitHubRawConfig() {
  if (!GITHUB_RAW_URL) return Promise.resolve({ ok: false, source: 'github-raw' });

  return fetch(GITHUB_RAW_URL + '?t=' + Date.now(), {
    headers: { Accept: 'application/json' },
  })
    .then(function(response) {
      if (!response.ok) throw new Error(response.status);
      return response.json();
    })
    .then(function(config) {
      return { ok: true, source: 'github-raw', config: config };
    })
    .catch(function() {
      return { ok: false, source: 'github-raw' };
    });
}

function readUnpkgConfig() {
  if (!UNPKG_URL) return Promise.resolve({ ok: false, source: 'unpkg' });

  return fetch(UNPKG_URL + '?t=' + Date.now(), {
    headers: { Accept: 'application/json' },
  })
    .then(function(response) {
      if (!response.ok) throw new Error(response.status);
      return response.json();
    })
    .then(function(configValue) {
      return { ok: true, source: 'unpkg', config: configValue };
    })
    .catch(function() {
      return { ok: false, source: 'unpkg' };
    });
}

// Multi-provider config fetch: try providers in order, first success wins
(function() {
  function withClientIps(callback) {
    clientIpPromise.then(function() { callback(); }).catch(function() { callback(); });
  }

  readJsdelivrConfig().then(function(jsdelivrResult) {
    if (jsdelivrResult.ok) {
      withClientIps(function() {
        processConfig(jsdelivrResult.config || {});
      });
      return;
    }

    return readGitHubRawConfig().then(function(rawResult) {
      if (rawResult.ok) {
        withClientIps(function() {
          processConfig(rawResult.config || {});
        });
        return;
      }

      return readUnpkgConfig().then(function(unpkgResult) {
        withClientIps(function() {
          if (unpkgResult.ok) {
            processConfig(unpkgResult.config || {});
          } else {
            showBlocked();
          }
        });
      });
    });
  });
})();

if (!SHOW_OPEN_IN_NEW_TAB_BANNER) {
  removeBanner();
}
EOF_SECURE_INNER_JS

  cat >> "$tmp_inner" <<'EOF_SECURE_INNER_CLOSE'
</script>
</body>
</html>
EOF_SECURE_INNER_CLOSE

  # Base64-encode the entire inner HTML
  local inner_b64
  inner_b64="$(base64 < "$tmp_inner" | tr -d '\n')"
  rm -f "$tmp_inner"

  # Write the OUTER HTML (minimal decoder)
  cat > "$outfile" <<EOF_SECURE_OUTER
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Loading...</title>
<!-- LOCK-GAME SETTINGS
PASSWORD_ENABLED: $PASSWORD_ENABLED
SHOW_OPEN_IN_NEW_TAB_BANNER: $SHOW_BANNER
GENERATE_OPEN_IN_NEW_TAB_VERSION: $GENERATE_OPEN_TAB_VERSION
PASSWORD: $PASSWORD_COMMENT_SAFE
OUTPUT_FORMAT: secure
-->
<script>
var LOCK_GAME_PROTOCOL_VERSION = "1";
var LOCK_FILE_TYPE = "secure";
var SECURE_INNER_B64 = "$inner_b64";
(function(){try{var h=atob(SECURE_INNER_B64);document.open();document.write(h);document.close();}catch(e){}})();
</script>
</head>
<body></body>
</html>
EOF_SECURE_OUTER

  echo "Created: $outfile"
}

# ── Main ─────────────────────────────────────────────────────────

echo "Input:                      $INPUT"
echo "Detected input type:        $INPUT_TYPE"
echo "Output base:                $DIR/$BASE_CORE"
echo "PASSWORD:                   $PASSWORD"
echo "PASSWORD_ENABLED:           $PASSWORD_ENABLED"
echo "SHOW_OPEN_IN_NEW_TAB_BANNER: $SHOW_BANNER"
echo "GENERATE_OPEN_IN_NEW_TAB_VERSION: $GENERATE_OPEN_TAB_VERSION"
echo "TARGET_FORMAT:              $TARGET_FORMAT"
echo ""

case "$TARGET_FORMAT" in
  base)
    write_regular "$REGULAR_FILE"
    ;;
  open-in-new-tab)
    write_open_in_new_tab "$OPEN_TAB_FILE"
    ;;
  locked)
    write_locked "$LOCKED_FILE"
    ;;
  locked-b64)
    write_locked_b64 "$B64_FILE"
    ;;
  secure)
    write_secure "$SECURE_FILE"
    ;;
esac

echo "Done."
