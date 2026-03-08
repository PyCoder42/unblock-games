# Lock Converter Problems (`Formatting Scripts/lock-game.sh` + `Formatting Scripts/sync-protocol-versions.sh`)

Last updated: 2026-03-08

## Current Open Problems

(None at this time.)

## Current Progress Snapshot

- All shared helper functions (naming, protocol detection, rg wrapper) are consolidated in `common.sh`.
  All three scripts (`lock-game.sh`, `sync-protocol-versions.sh`, `create-folder-from-html.sh`) source it.
- Banner is generated from one shared template function (`render_banner_block`) so future banner edits are single-point changes.
- Banner controls include:
  - full-width open-in-new-tab click area (about:blank opener — excluding control hitboxes)
  - fullscreen button
  - external-link (legacy open-in-new-tab) button
  - close (X) full-height right-edge hitbox
- `lockBannerOpenCurrent` uses the `<!-- LOCK-BANNER START/END -->` comment markers for reliable stripping,
  and detects `gameFrame` iframes to pull game HTML from the correct source.
- Fullscreen is preserved through login: when fullscreen is active, the game loads in an iframe
  below the banner instead of a full page replacement, so the browser does not exit fullscreen.
  The banner stays visible for re-fullscreening; closing the banner expands the game iframe to full size.
- Password-protected files (`PASSWORD_ENABLED: true`) always have `SHOW_OPEN_IN_NEW_TAB_BANNER: true`
  (enforced at generation time). Banner HTML is only included when `SHOW_BANNER` is true.
- Sync script has a banner-upgrade pass (`--upgrade-banner` / `--no-upgrade-banner`) that upgrades
  files containing legacy banner markup.
- Base files are enforced as clean files with no `LOCK-GAME SETTINGS` comment metadata.
- `ripgrep` (`rg`) is checked at startup; if missing, a `perl` fallback provides identical matching.
- `create-folder-from-html.sh` supports `--dry-run`.
- **Secure variant (`-secure.html`) implemented**:
  - Double base64 encoding (outer `SECURE_INNER_B64` → inner HTML with `REAL_PAGE_B64`).
  - Remote password management via dual-source config (jsdelivr.net primary, Google Apps Script JSONP fallback).
  - Per-game blocking: permanent block or time-based block (shows fake Chrome error page).
  - Admin panel (`admin-panel.html`) writes to both sources and shows sync status.
  - `setup-secure.sh` handles interactive first-time setup (GitHub repo, GAS deployment, credential storage).
  - `common.sh` updated with `is_protocol_secure()` detection and secure naming support across all helpers.
  - Round-trip extraction tested: secure → base correctly double-decodes back to clean game HTML.
