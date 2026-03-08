# Unblock Games

HTML game files served over local WiFi to bypass network restrictions. Each game lives in its own folder with protocol-managed file variants.

## Project Structure

```
Formatting Scripts/
  common.sh              # Shared helpers (naming, protocol detection, rg wrapper) — edit HERE for shared logic
  lock-game.sh           # Convert/wrap HTML into locked variants
  sync-protocol-versions.sh  # Regenerate all locked files from base files
  create-folder-from-html.sh # Import new HTML games into protocol folder layout
  setup-secure.sh        # Interactive setup for secure variant (dual-source config)
  gas-server.js          # Google Apps Script doGet() handler for remote config
  admin-panel-template.html  # Admin panel template (placeholders filled by setup)
<Game Folder>/
  <name>-regular.html        # Base (clean game HTML, no protocol metadata)
  <name>-locked.html         # Template-literal locked variant (password-protected)
  <name>-secure.html         # Remote-managed variant (double b64, remote password + blocking)
Pokemon Showdown/
  pokemon-showdown-host.js   # Node.js HTTP/WebSocket proxy for Pokemon Showdown
config.json                    # Remote config (password, blocked games) — served via jsdelivr CDN + GAS
ultimate-game-stash.html       # Main landing page with all game links
.secure-config               # [gitignored] Credentials for secure variant
admin-panel.html             # [gitignored] Generated admin panel with embedded credentials
```

## Key Conventions

- **"base" vs "-regular"**: Scripts/CLI use `base`; files on disk use `-regular.html`. See LOCKING_PROTOCOL.md.
- **Eaglercraft special naming**: `eaglercraft-regular-1-12.html` (version suffix after `-regular`).
- **All shared helpers live in `common.sh`** — never duplicate logic across the 3 scripts.
- **Password-protected files always have SHOW_BANNER=true** (enforced at generation time).
- **Banner uses `<!-- LOCK-BANNER START/END -->` comment markers** for reliable stripping.
- **Fullscreen persistence**: When fullscreen is active during password entry, game loads in an iframe (preserves fullscreen). When not fullscreen, the page is replaced entirely and banner auto-removes.
- **Secure variant uses double base64**: Outer HTML has `SECURE_INNER_B64` (only a blob in view-source). Inner HTML contains banner, password logic, and `REAL_PAGE_B64` (the actual game).
- **Dual-source config**: Secure files try jsdelivr.net first (CDN, fast), fall back to Google Apps Script (JSONP, never blocked at schools).
- **`.secure-config` and `admin-panel.html` are gitignored** — they contain credentials and ARE the admin access key.

## Script Usage

```bash
# Regenerate all locked + secure files from base files
./Formatting\ Scripts/sync-protocol-versions.sh --keep base,locked,secure --force

# Convert a single file
./Formatting\ Scripts/lock-game.sh "Drive Mad/drive-mad-regular.html"

# Generate a secure variant
./Formatting\ Scripts/lock-game.sh "Drive Mad/drive-mad-regular.html" "" secure

# Import a new HTML game
./Formatting\ Scripts/create-folder-from-html.sh new-game.html --folder "New Game"

# Dry-run (preview what would change)
./Formatting\ Scripts/create-folder-from-html.sh new-game.html --dry-run

# Set up secure variant (interactive — run once)
./Formatting\ Scripts/setup-secure.sh
```

## Testing

```bash
# Serve files locally for Chrome testing
python3 -m http.server 8888

# Pokemon Showdown proxy
node "Pokemon Showdown/pokemon-showdown-host.js"
```

Test fullscreen flow: open a locked or secure file, click fullscreen button on banner, enter password (`supercoolpassword`), verify game loads in iframe with banner staying visible. Close banner verifies iframe expands to full size.

## Current Status

- All scripts refactored to source `common.sh` (no duplicated helpers)
- Banner: fullscreen, external-link (SVG box-arrow icon), legacy open, close (X) buttons
- Fullscreen preserved through login via iframe approach
- `rg` (ripgrep) checked at startup with `perl` fallback
- `create-folder-from-html.sh` supports `--dry-run`
- Pokemon Showdown proxy file paths fixed
- All 7 game folders have base + locked + secure variants
- **Secure variant deployed**: double-b64 encoding, remote password, per-game blocking, dual-source config (jsdelivr + GAS), admin panel
- GAS web app deployed and tested — auto-initializing config server
- `config.json` in repo root — served via jsdelivr CDN (primary) and GAS Script Properties (fallback)
- Git repo at `PyCoder42/unblock-games` on GitHub

## How to Continue

1. **Make repo PUBLIC**: jsdelivr CDN requires a public repo to serve `config.json`. Run: `gh repo edit PyCoder42/unblock-games --visibility public`
2. **Test in browser**: `python3 -m http.server 8888`, then open a `-secure.html` file
3. **Admin panel**: Open `admin-panel.html` to manage password and per-game blocking

## Known Issues

None at this time. See LOCK_CONVERTER_PROBLEMS.md for historical issues.
