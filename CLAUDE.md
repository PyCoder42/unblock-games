# CLAUDE.md

This file is the **single source of truth** for any agent working on this repository. Read it fully before touching code.

## What This Is

HTML game files served over local WiFi to bypass school network restrictions. Each game lives in its own folder inside `Games/` with protocol-managed file variants. A remote config system (jsDelivr CDN + GitHub raw fallback) enables password management and per-game blocking from a phone via the admin panel.

## Repository Organization

### Directory Structure

```
.
├── CLAUDE.md                  # THIS FILE — canonical project knowledge base
├── DO NOT TOUCH - Mr Mine Page Sources/  # Page sources for reference (not game files)
├── config.json                # Remote config (password, blocked games, allowed IPs)
├── Games/                     # All game folders
│   ├── Drive Mad/
│   ├── Escape Road/
│   ├── GN Math/
│   ├── Minecraft/
│   ├── Mr Mine/
│   └── Pokemon Showdown/
├── Admin Panel/               # Admin panel HTML files (gitignored contents)
├── Formatting Scripts/        # All build/generation scripts
├── Proxy/                     # Cloudflare Worker proxy for accessing blocked sites
├── tests/                     # Test files (unit tests, CDN tester, proxy tester)
├── docs/                      # Documentation (LOCKING_PROTOCOL.md, delegation files)
├── game-data/                 # Encrypted game data (.enc.json) served via jsDelivr
├── .claude/                   # Claude Code session data
├── .secure-config             # Credentials (gitignored)
└── .game-keys                 # Encryption keys (gitignored)
```

### IMPORTANT: File Organization Rules

- **No stray MD/doc files in the root directory.** Everything has a home:
  - Project knowledge, plans, and implementation status → **this file (CLAUDE.md)**
  - Usage/reference docs → `docs/`
  - Tests and test utilities → `tests/`
  - Scripts → `Formatting Scripts/`
  - Games → `Games/<Game Name>/`
  - Delegation/handoff files → `docs/`
- **CLAUDE.md is where implementation plans and project state go.** Do not create separate plan files or progress trackers unless explicitly told to. A new agent should be able to read CLAUDE.md and be fully caught up.
- **Update CLAUDE.md frequently** when making architectural changes, adding features, or changing how things work.

## Commands

```bash
# Regenerate all secure files from base files (most common operation)
./Formatting\ Scripts/sync-protocol-versions.sh --force

# Regenerate with explicit variant set
./Formatting\ Scripts/sync-protocol-versions.sh --keep base,secure --force

# Convert a single file to a specific format
./Formatting\ Scripts/lock-game.sh "Games/Drive Mad/drive-mad-regular.html" "" secure

# Import a new HTML game into protocol folder layout
./Formatting\ Scripts/create-folder-from-html.sh new-game.html --folder "New Game"

# Dry-run (preview what sync would change)
./Formatting\ Scripts/sync-protocol-versions.sh --dry-run

# Run tests
node --test tests/secure-config.test.mjs

# Serve files locally for browser testing
python3 -m http.server 8888

# Sync remote config to jsdelivr
node "Formatting Scripts/sync-remote-config.mjs" --dry-run --no-local
node "Formatting Scripts/sync-remote-config.mjs"

# Regenerate admin panel from template (after template changes)
./Formatting\ Scripts/setup-secure.sh --regenerate

# Create a fake admin panel with its own GitHub PAT
./Formatting\ Scripts/setup-secure.sh --fake "Person's Name" [github-pat]

# Pokemon Showdown proxy (local)
node "Games/Pokemon Showdown/pokemon-showdown-host.js"

# Pokemon Showdown proxy (cross-WiFi via Cloudflare tunnel)
./Games/Pokemon\ Showdown/start-pokemon-showdown-remote.sh
```

## Architecture

### File Variant System

Each game folder inside `Games/` contains these HTML files:

- **`*-regular.html`** (base) — Clean game HTML, no protocol metadata. Source of truth.
- **`*-open-in-new-tab.html`** — Lightweight wrapper that opens the game in a new tab. Used for embedding in code editors like hcodx.com.
- **`*-secure.html`** — Outer HTML contains an opaque base64 blob (`SECURE_INNER_B64`). Inner HTML (decoded at runtime) has the password UI, remote config fetch, per-game blocking, and fetches the actual game from encrypted CDN data (`game-data/*.enc.json`). View-source reveals nothing useful.

All variants are generated from the base file by `lock-game.sh`. The `sync-protocol-versions.sh` script batch-generates across all game folders.

**Note:** The `*-locked.html` variant (template-literal wrapping) was previously used but has been phased out. Current default keep set is `base,secure`.

### Remote Config System

**GAS (Google Apps Script) has been fully removed.** The system now uses CDN-only config fetching.

Secure files fetch their password/blocking config at runtime from a fallback chain:

1. **jsDelivr CDN** (primary) — Serves `config.json` from this repo via `cdn.jsdelivr.net/gh/REPO@<tag>/config.json`. Uses exact version tags (not branch refs) for cache reliability.
2. **GitHub raw** (fallback) — `raw.githubusercontent.com/REPO/main/config.json`. Works when jsDelivr is down.
3. **Auto-block** — If ALL providers fail, `showBlocked()` fires to prevent unauthenticated access.

**Write flow:** Admin panel writes to GitHub API → creates a version tag → purges jsDelivr cache.

### Encrypted Game Data (`game-data/`)

Secure variants do NOT embed the game HTML as base64 inline. Instead:

1. `lock-game.sh` encrypts the game HTML with AES-256-GCM using `generate-enc-game-data.mjs`
2. The encrypted payload is stored in `game-data/<game-id>.enc.json`
3. The encryption key is embedded in the secure HTML file
4. At runtime, `fetchAndDecryptGame()` fetches the encrypted data from jsDelivr and decrypts in-browser

This means even decoding the base64 outer layer of a secure file reveals NO game HTML — just the password UI and a decryption key that requires the CDN-hosted encrypted data. Keys are stored in `.game-keys` (gitignored).

### Planned: Multi-Provider Config (unpkg as 3rd provider)

Adding unpkg (Cloudflare-backed npm CDN) as a 3rd config provider for redundancy. Requires publishing config as a tiny npm package. Chain becomes: jsDelivr → GitHub raw → unpkg → showBlocked().

### Script Dependency Chain

All shell scripts source `common.sh` for shared logic:
- **`common.sh`** — Naming helpers (`variant_stem_from_raw`, `derive_standard_base`), protocol detection (`is_protocol_locked`, `is_protocol_secure`), `rg` wrapper with perl fallback. Edit HERE for any shared logic.
- **`lock-game.sh`** — Single-file conversion. Reads `.secure-config` for jsDelivr/GitHub raw URLs when generating secure variants. Handles extraction from any protocol format back to base.
- **`sync-protocol-versions.sh`** — Batch generation. Scans game folders, finds base files, generates missing variants, removes extras not in `--keep` set. Excludes `Formatting Scripts/`, `Admin Panel/`, `tests/`.
- **`create-folder-from-html.sh`** — Imports a raw HTML file into a new protocol-managed folder.

### Admin Panel System

- **Real panels** have a GitHub PAT with write access. Full control including config editing.
- **Fake panels** have their own fine-grained GitHub PAT. Can do normal config operations (password, block/unblock) but revoking the PAT = total lockout.
- **Template:** `Formatting Scripts/admin-panel-template.html` with placeholders filled by `setup-secure.sh`.
- **Template variables:** `{{JSDELIVR_URL}}`, `{{GITHUB_RAW_URL}}`, `{{GITHUB_REPO}}`, `{{GITHUB_PAT}}`, `{{PANEL_MODE}}` (`"real"` or `"fake"`).
- **`.secure-config` and `Admin Panel/` contents are gitignored** — they contain credentials.

### Shared Normalization Logic

Game ID normalization and IP validation logic is duplicated across codebases that cannot share modules:
- `gas-server.js` (Google Apps Script — no module imports, kept for reference)
- `admin-panel-template.html` (browser JS — no Node.js)
- `remote-config-sync.mjs` (Node.js — can import)

Changes to normalization (e.g., `normalizeGameId`, `normalizeAllowedIps`, `normalizeConfig`) must be applied to all three files.

### Cloudflare Worker Proxy

A Cloudflare Worker that proxies blocked websites through `workers.dev`. School Chromebooks can reach Cloudflare Workers (confirmed by CDN testing). The Worker:

1. Receives a URL as a path parameter (`your-worker.workers.dev/https://example.com`)
2. Fetches the target page server-side
3. Rewrites internal links to route back through the Worker
4. Returns the full HTML with proper content types

**Status:** Basic implementation in `Proxy/worker.js` with test page in `tests/proxy-tester.html`.

**Pokemon Showdown migration:** Once the proxy is production-ready, Pokemon Showdown will switch from its current Cloudflare Tunnel approach (`start-pokemon-showdown-remote.sh` + `pokemon-showdown-host.js`) to using the Cloudflare Worker proxy instead. This eliminates the need for a local Node.js server and tunnel — the Worker handles everything server-side.

### Smash Karts Technical Details

Smash Karts requires special handling due to its Unity WebGL architecture:

**jsDelivr 20MB limit:** Unity build files (.wasm ~51MB, .data ~33MB) exceed jsDelivr's 20MB file limit (HTTP 403). Solution: `Pok12d/ta` repo splits files into two zip parts (~17MB each).

**Loading pipeline:**
1. JSZip loads from jsDelivr
2. Two zip parts download and combine in-browser
3. Extracted files become blob URLs with correct MIME types
4. URL interception (fetch/XHR/script src/image src) redirects Unity requests to blob URLs
5. `blob.js` (pre-decompressed framework JS) loads from CDN
6. Unity loader uses blob URLs for all build files

**Monkeypatch architecture:** The game uses `document.open()/write()/close()` for page injection. DOM-level patches (`createElement`, `setAttribute`, `Image.src`) applied before document replacement do NOT reliably survive — they're lost when the document context is replaced. The fix is to move ALL monkeypatches INSIDE the written HTML as a top-of-page `<script>` block.

**Mocks required:** Firebase (auth, functions, DataSnapshot), PokiSDK, gtag/dataLayer. All must be inline — no external dependencies.

**Domains:** Only `cdn.jsdelivr.net/gh/Pok12d/ta@main/sma/` for assets. Multiplayer uses `ns.photonengine.io:19093` (WebSocket, may be blocked at school).

### CDN Accessibility (School Chromebook)

Tested via `tests/cdn-tester.html`:

| Status | CDNs |
|--------|------|
| **CORS OK** | jsDelivr (all endpoints), cdnjs, unpkg, esm.sh, Skypack, Google CDN, Microsoft CDN, GitHub raw |
| **No CORS** | Cloudflare Workers, Vercel, Netlify |
| **Blocked** | Statically, GitHack, Cloudflare Pages, Render |

"No CORS" means direct navigation works (good for proxy), but `fetch()` from another page doesn't (not good for config fetching).

## Key Conventions

- **"base" vs "-regular"**: Scripts/CLI use `base`; files on disk use `-regular.html`. See `docs/LOCKING_PROTOCOL.md`.
- **Eaglercraft special naming**: Version suffix goes after the variant kind: `eaglercraft-regular-1-12.html`, `eaglercraft-secure-1-12.html`. The `extract_eagler_tail` / `variant_stem_from_raw` functions handle this.
- **Banner markers**: `<!-- LOCK-BANNER START/END -->` comment pairs. Banner version tracked by `__LOCK_BANNER_V4__`.
- **Fullscreen persistence**: When fullscreen is active during password entry, game loads in an iframe (preserves fullscreen). When not fullscreen, page is replaced entirely.
- **Default password**: `supercoolpassword`
- **config.json schema**: `{ password, passwords[], blocked: {gameId: true|ISO_date}, games: [gameId...], allowedIps: {ip: {label}} }`
- **jsDelivr versioning**: Writes create semver tags (`0.0.<timestamp><random>`) instead of using `@main`/`@latest` branch refs, because jsdelivr metadata lags behind branch HEAD.
- **GN-Math pattern**: Uses a multi-repo structure: `zones.json` catalog in `gn-math/assets`, game HTML files in `gn-math/html`, covers in `gn-math/covers` — all served via jsDelivr. Games are fetched as text and written into an iframe via `contentDocument.open()/write()/close()`. Each game is a self-contained HTML file pointing to its own jsDelivr-hosted assets. The main repo was DMCA'd by Poki (Dec 2025) but asset repos still work. The local `gn-math-regular.html` uses `<base href>` to resolve against the CDN. The Cloudflare Worker proxy follows this same fetch-and-serve pattern but server-side.

## Testing

```bash
node --test tests/secure-config.test.mjs
```

Tests cover: GAS server logic (reference), game ID normalization, IP validation/filtering, config normalization, admin template constraints, secure file generation markers, and jsdelivr version resolution. **Current status: 29/29 passing.**

Manual browser test: serve locally (`python3 -m http.server 8888`), open a secure file, enter password, verify game loads.

### Game File Testing Checklist

Test in this order:
1. **hcodx.com** (primary) — Go to hcodx.com, click "Open saved or import projects", click "Select files", open the `-secure` variant. Select it in the file list, click the play button (Run in New Tab). Enter password, verify game loads.
2. **`file://`** — Open the `-regular.html` directly in Chrome/Safari via `file:///path/to/game.html`.
3. **localhost** — Serve via `python3 -m http.server 8888`, open in browser.
4. **`-secure` variant compatibility** — Test on various code editors to verify the fullscreen banner works everywhere.

## Current Implementation Status

### Completed
- GAS removal from all client-side files (admin panel, secure template, lock-game.sh)
- GitHub raw as 2nd config provider (jsDelivr → GitHub raw → showBlocked)
- PAT-based fake admin panel system (replaces GAS fake keys)
- CDN tester with export functionality (`tests/cdn-tester.html`)
- All tests updated and passing (29/29)
- Encrypted game data system (`game-data/`, `generate-enc-game-data.mjs`)
- Directory reorganization (games moved to `Games/`, tests to `tests/`, docs to `docs/`)

### In Progress
- **Multi-provider config** — Adding unpkg as 3rd CDN provider
- **Cloudflare Worker proxy** — Basic proxy for accessing blocked websites
- **Smash Karts loading fix** — Moving monkeypatches inside written HTML to survive document replacement
- **Static website proxy** — `fetch-page.mjs` for fetching pages at home, serving via CDN at school

### Architecture Decisions Log
- **Why jsDelivr over GitHub raw?** jsDelivr is not blocked at school; GitHub.com is. jsDelivr serves GitHub repo files via CDN.
- **Why encryption over base64?** Base64 is trivially decodable. AES-256-GCM encryption with CDN-hosted data means even view-source of the decoded secure file reveals nothing.
- **Why version tags over branch refs?** jsDelivr metadata API lags behind branch HEAD. Exact version tags are immediately available.
- **Why no GAS?** GAS was blocked on the school network. The system now uses CDN-only fetching (accessible at school) with GitHub API writes (done from home/phone).
