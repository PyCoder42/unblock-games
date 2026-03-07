# Pokemon Showdown Instructions

This folder is intentionally organized with one canonical runtime path:

- One host implementation: `pokemon-showdown-host.js`
- One startup script: `start-pokemon-showdown-remote.sh`
- One game file: `pokemon-showdown-regular.html`

No duplicate host/proxy variants are kept.

## Start (works across different Wi-Fi networks)

From `/Users/saahir/Desktop/Unblock Games`:

```bash
./Pokemon\ Showdown/start-pokemon-showdown-remote.sh
```

What this does:

1. Starts the local host/proxy (`pokemon-showdown-host.js`) on `127.0.0.1:8787`
2. Starts a Cloudflare quick tunnel
3. Prints a public URL like:
   - `https://<random>.trycloudflare.com/pokemon-showdown`

Keep that terminal open while playing. Press `Ctrl+C` to stop.

## Open the game

- On any device/network, open the printed URL:
  - `https://<random>.trycloudflare.com/pokemon-showdown`

## If using another HTML/tester page

Use the printed tunnel origin as proxy:

- `?proxy=https://<random>.trycloudflare.com&wsPath=/showdown`

The regular launcher stores this proxy and retries cleanly.

## Notes

- `cloudflared` is auto-installed via Homebrew if missing.
- The tunnel hostname changes each run (expected with quick tunnels).
