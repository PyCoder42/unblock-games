# Game Locking Protocol (Base + Open-Tab + Locked + Locked-B64)

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

## Folder And Naming Rules

- Keep game families in folders (examples: `Drive Mad`, `Escape Road`, `Minecraft`).
- Use lowercase-dash filenames.
- Keep paired names consistent:
  - `drive-mad-regular.html`
  - `drive-mad-open-in-new-tab.html`
  - `drive-mad-locked.html`
  - `drive-mad-locked-b64.html`

## Base File Rule

Base files (`*-regular.html`) should be clean game files and must not contain the `LOCK-GAME SETTINGS` protocol comment block.

## Protocol Signals In Generated Files

Generated locked files include protocol markers:

- `LOCK_GAME_PROTOCOL_VERSION`
- `LOCK_FILE_TYPE` (`locked` or `locked-b64`)
- `PASSWORD`, `PASSWORD_ENABLED`, `SHOW_OPEN_IN_NEW_TAB_BANNER`

`lock-game.sh` uses these markers to detect protocol-compliant input.

## Conversion Logic

### If input is protocol-compliant (`locked` or `locked-b64`)

`lock-game.sh` extracts the real page payload and converts directly to the requested format (`base`, `open-in-new-tab`, `locked`, or `locked-b64`) without treating the lock wrapper as the game source.

### If input is not protocol-compliant

`lock-game.sh` treats input as a regular game HTML file and wraps the whole page into the requested output format.

## Script Usage

```bash
./Formatting\ Scripts/lock-game.sh "<input-file.html>" [password] [format]
```

### Parameters

- `password` (optional): overrides the default password (`supercoolpassword`) for that run.
- `format` (optional): `base`, `open-in-new-tab`, `locked`, or `locked-b64`.

If `format` is omitted, script defaults to `locked-b64`.

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
