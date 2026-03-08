# Game Locking Protocol (Base + Open-Tab + Locked + Locked-B64 + Secure)

This protocol defines how to manage game files and how `lock-game.sh` decides whether to convert or fully wrap content.

## Naming Convention: "base" vs "-regular"

**Internally** (in scripts, docs, and CLI flags) we use the term **base** to refer to the
clean, unwrapped game file. **On disk**, this file always has the suffix **`-regular.html`**.

| Context | Term used |
|---------|-----------|
| Script arguments (`--keep base`, format `base`) | `base` |
| Internal function names (`derive_standard_base`, `variant_stem_from_raw … "base"`) | `base` |
| File names on disk | `<name>-regular.html` |

This distinction keeps CLI/code readable ("base" is shorter) while keeping file names
unambiguous (no file is ever named just `<name>.html`).

## Shared Library

All common helper functions live in `Formatting Scripts/common.sh` and are sourced by
`lock-game.sh`, `sync-protocol-versions.sh`, and `create-folder-from-html.sh`.
**Always edit `common.sh`** when changing naming logic, protocol detection, or the `rg` wrapper.

## Supported File Types

1. Base: `<name>-regular.html`
2. Open-in-new-tab: `<name>-open-in-new-tab.html`
3. Locked (template text): `<name>-locked.html`
4. Locked (base64 payload): `<name>-locked-b64.html`
5. Secure (remote-managed): `<name>-secure.html`

## Folder And Naming Rules

- Keep game families in folders (examples: `Drive Mad`, `Escape Road`, `Minecraft`).
- Use lowercase-dash filenames.
- Keep paired names consistent:
  - `drive-mad-regular.html`
  - `drive-mad-open-in-new-tab.html`
  - `drive-mad-locked.html`
  - `drive-mad-locked-b64.html`
  - `drive-mad-secure.html`

## Base File Rule

Base files (`*-regular.html`) should be clean game files and must not contain the `LOCK-GAME SETTINGS` protocol comment block.

## Protocol Signals In Generated Files

Generated locked files include protocol markers:

- `LOCK_GAME_PROTOCOL_VERSION`
- `LOCK_FILE_TYPE` (`locked`, `locked-b64`, or `secure`)
- `PASSWORD`, `PASSWORD_ENABLED`, `SHOW_OPEN_IN_NEW_TAB_BANNER`
- `SECURE_INNER_B64` (secure variant only — the double-b64-encoded payload)

`lock-game.sh` uses these markers to detect protocol-compliant input.

## Conversion Logic

### If input is protocol-compliant (`locked`, `locked-b64`, or `secure`)

`lock-game.sh` extracts the real page payload and converts directly to the requested format (`base`, `open-in-new-tab`, `locked`, `locked-b64`, or `secure`) without treating the lock wrapper as the game source.

For `secure` input, extraction is a two-step decode: outer `SECURE_INNER_B64` → inner HTML → `REAL_PAGE_B64` → clean game HTML.

### If input is not protocol-compliant

`lock-game.sh` treats input as a regular game HTML file and wraps the whole page into the requested output format.

## Script Usage

```bash
./Formatting\ Scripts/lock-game.sh "<input-file.html>" [password] [format]
```

### Parameters

- `password` (optional): overrides the default password (`supercoolpassword`) for that run.
- `format` (optional): `base`, `open-in-new-tab`, `locked`, `locked-b64`, or `secure`.

If `format` is omitted, script defaults to `locked-b64`.

### Secure Format Prerequisites

The `secure` format requires a `.secure-config` file in the project root (created by `setup-secure.sh`).
This file contains URLs for the dual-source config system. See the Secure Variant section below.

## Examples

Generate locked-b64 from base:

```bash
./Formatting\ Scripts/lock-game.sh "Drive Mad/drive-mad-regular.html"
```

Generate base from a protocol-locked file:

```bash
./Formatting\ Scripts/lock-game.sh "Drive Mad/drive-mad-locked.html" "" base
```

Generate only b64 with explicit password:

```bash
./Formatting\ Scripts/lock-game.sh "Drive Mad/drive-mad-regular.html" "newpassword123" locked-b64
```

Convert protocol locked -> locked-b64:

```bash
./Formatting\ Scripts/lock-game.sh "Drive Mad/drive-mad-locked.html" "" locked-b64
```

Convert protocol locked-b64 -> locked:

```bash
./Formatting\ Scripts/lock-game.sh "Drive Mad/drive-mad-locked-b64.html" "" locked
```

## Add A New Folder (Human/AI Checklist)

1. Create folder: `mkdir -p "New Game Folder"`
2. Add base HTML with lowercase-dash filename (`<name>-regular.html`).
3. Run `lock-game.sh` on the base file.
4. Verify the expected output types exist.
5. Add links to `index.html`.

## Validation Commands

List base files:

```bash
find . -type f -name "*-regular*.html" | sort
```

List open-tab versions:

```bash
find . -type f -name "*-open-in-new-tab.html" | sort
```

List locked:

```bash
find . -type f -name "*-locked.html" | sort
```

List locked-b64:

```bash
find . -type f -name "*-locked-b64.html" | sort
```

List secure:

```bash
find . -type f -name "*-secure.html" | sort
```

## Secure Variant

The `secure` format adds remote password management and per-game blocking on top of the locked-b64 approach.

### Architecture

```
Outer HTML (view-source shows only this):
  - LOCK-GAME SETTINGS comment
  - LOCK_GAME_PROTOCOL_VERSION, LOCK_FILE_TYPE = "secure"
  - SECURE_INNER_B64 = "<base64 blob>"
  - Minimal decoder: atob() → DOM replacement

Inner HTML (decoded at runtime, invisible to view-source):
  - Banner (LOCK-BANNER START/END markers)
  - Loading screen → Password screen
  - Config vars: GAME_ID, JSDELIVR_URL, GAS_URL, REAL_PAGE_B64
  - Dual-source config fetch logic
  - processConfig(): checks blocks, sets remote password, shows prompt
  - showBlocked(): fake Chrome "This site can't be reached" error page
  - checkPw(): validates against remote password
  - openRealPage(): fullscreen-aware game loader (iframe or full-page replace)
```

### Dual-Source Config System

Game files fetch config from two sources for resilience:

1. **Primary — jsdelivr.net**: `fetch()` call to `cdn.jsdelivr.net/gh/<repo>@main/config.json` (CORS-enabled CDN that proxies a public GitHub repo).
2. **Fallback — Google Apps Script**: JSONP via `<script>` tag injection to `script.google.com/macros/s/<id>/exec` (avoids CORS issues from GAS redirect chain).

If both fail, the game shows the fake blocked page.

### Config Format (`config.json`)

```json
{
  "password": "currentpassword",
  "blocked": {
    "drive-mad": true,
    "slope": "2026-03-15T14:30:00"
  },
  "games": ["drive-mad", "slope", "subway-surfers"]
}
```

- `password`: The current shared password (empty string = no password required).
- `blocked`: Per-game blocking. `true` = permanent block. ISO datetime string = blocked until that time.
- `games`: List of known game IDs.

### Setup

```bash
./Formatting\ Scripts/setup-secure.sh
```

Interactive script that:
1. Collects GitHub repo, PAT, Google Apps Script URL, and secret key.
2. Tests both endpoints.
3. Scans game folders to build the initial games list.
4. Initializes config in both sources (GitHub API + GAS).
5. Writes `.secure-config` (gitignored, contains credentials).
6. Generates `admin-panel.html` from template (gitignored, the file IS the admin key).

### Admin Panel

The generated `admin-panel.html` is a self-contained dark-themed UI for:
- Changing the shared password
- Per-game block/unblock (permanent or time-limited)
- Adding new games

It writes to **both** sources (GitHub API → purge jsdelivr cache → GAS fullSync) and shows sync status.

### Google Apps Script Server

`gas-server.js` contains the `doGet()` handler to deploy as a Google Apps Script web app:
- **read** action: Returns config as JSONP (public, no auth).
- **write** actions: Require `secretKey` validation. Supports `updatePassword`, `block`, `unblock`, `timeblock`, `addGame`, `fullSync`.

### Files

| File | Gitignored | Purpose |
|------|-----------|---------|
| `Formatting Scripts/setup-secure.sh` | No | Interactive setup wizard |
| `Formatting Scripts/gas-server.js` | No | Google Apps Script server code |
| `Formatting Scripts/admin-panel-template.html` | No | Template with `{{placeholders}}` |
| `.secure-config` | **Yes** | Credentials (JSDELIVR_URL, GAS_URL, GITHUB_REPO, GITHUB_PAT, GAS_SECRET) |
| `admin-panel.html` | **Yes** | Generated admin panel with embedded credentials |
