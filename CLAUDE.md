# Unblock Games

HTML game files served over local WiFi to bypass network restrictions. Each game lives in its own folder with protocol-managed file variants.

## Project Structure

```
Formatting Scripts/
  common.sh              # Shared helpers (naming, protocol detection, rg wrapper) — edit HERE for shared logic
  lock-game.sh           # Convert/wrap HTML into locked variants
  sync-protocol-versions.sh  # Regenerate all locked files from base files
  create-folder-from-html.sh # Import new HTML games into protocol folder layout
<Game Folder>/
  <name>-regular.html        # Base (clean game HTML, no protocol metadata)
  <name>-locked-b64.html     # Base64-encoded locked variant (primary distribution format)
  <name>-locked.html         # Template-literal locked variant (optional)
  <name>-open-in-new-tab.html # Banner-only variant (optional)
Pokemon Showdown/
  pokemon-showdown-host.js   # Node.js HTTP/WebSocket proxy for Pokemon Showdown
```

## Key Conventions

- **"base" vs "-regular"**: Scripts/CLI use `base`; files on disk use `-regular.html`. See LOCKING_PROTOCOL.md.
- **Eaglercraft special naming**: `eaglercraft-regular-1-12.html` (version suffix after `-regular`).
- **All shared helpers live in `common.sh`** — never duplicate logic across the 3 scripts.
- **Password-protected files always have SHOW_BANNER=true** (enforced at generation time).
- **Banner uses `<!-- LOCK-BANNER START/END -->` comment markers** for reliable stripping.
- **Fullscreen persistence**: When fullscreen is active during password entry, game loads in an iframe (preserves fullscreen). When not fullscreen, `document.write()` replaces the page and banner auto-removes.

## Script Usage

```bash
# Regenerate all locked files from base files (most common operation)
./Formatting\ Scripts/sync-protocol-versions.sh --force

# Convert a single file
./Formatting\ Scripts/lock-game.sh "Drive Mad/drive-mad-regular.html"

# Import a new HTML game
./Formatting\ Scripts/create-folder-from-html.sh new-game.html --folder "New Game"

# Dry-run (preview what would change)
./Formatting\ Scripts/create-folder-from-html.sh new-game.html --dry-run
```

## Testing

```bash
# Serve files locally for Chrome testing
python3 -m http.server 8888

# Pokemon Showdown proxy
node "Pokemon Showdown/pokemon-showdown-host.js"
```

Test fullscreen flow: open a locked-b64 file, click fullscreen button on banner, enter password (`supercoolpassword`), verify game loads in iframe with banner staying visible. Close banner verifies iframe expands to full size.

## Current Status

- All scripts refactored to source `common.sh` (no duplicated helpers)
- Banner: fullscreen, external-link (SVG box-arrow icon), legacy open, close (X) buttons
- Fullscreen preserved through login via iframe approach
- `rg` (ripgrep) checked at startup with `perl` fallback
- `create-folder-from-html.sh` supports `--dry-run`
- Pokemon Showdown proxy file paths fixed
- All 7 game folders regenerated and tested

## How to Continue

1. **Remote kill switch**: Design a mechanism for remotely disabling shared b64 files (make them look "blocked"). Consider a timed break feature. Planning stage — not yet implemented.
2. **Better password security**: Plan a `locked-b64-hiddenpassword` variant with encrypted/hidden password. The user wants to change the password without needing a laptop (a "hidden entrance in the code"). Planning stage.
3. **Git**: First commit hasn't been made yet. Push to private GitHub repo (PyCoder42 account).

## Known Issues

None at this time. See LOCK_CONVERTER_PROBLEMS.md for historical issues.
