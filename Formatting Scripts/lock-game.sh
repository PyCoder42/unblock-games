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
#   base | open-in-new-tab | locked | locked-b64
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

INPUT="${1:-}"
CLI_PASSWORD="${2:-}"
CLI_FORMAT="${3:-}"
DEFAULT_PASSWORD="supercoolpassword"

if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
  echo "Usage: $0 <input-file.html> [password] [format]"
  echo ""
  echo "Formats: base | open-in-new-tab | locked | locked-b64"
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
if is_protocol_locked_b64 "$INPUT"; then
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
    echo "Valid formats: base | open-in-new-tab | locked | locked-b64"
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

function getGameHtml() { return REAL_PAGE; }

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
esac

echo "Done."
