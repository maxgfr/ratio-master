---
name: ratio-master
description: Run the ratio-master CLI to inspect a .torrent file or send seeding announces to its tracker (qBittorrent/uTorrent emulation, upload speed, DNS-over-HTTPS). Use when the user wants to run ratio-master on a torrent, check a torrent's metadata or info_hash, or fix announces that fail (network error, tracker error, DNS blocked by the ISP).
---

# ratio-master

`ratio-master` reads a `.torrent` file, then sends real HTTP announces to its tracker as a
seeder (`left=0`, `downloaded=0`), reporting an upload that grows at the chosen speed. It runs
until stopped and sends `event=stopped` on exit.

## Install

```bash
brew install maxgfr/tap/ratio-master      # provides `ratio-master`
# or from a clone: ./ratio-master.sh (bash 4+, curl, shasum or openssl; nc optional)
```

## Workflow

1. **Inspect first, offline**: `ratio-master --dry-run <file.torrent>`.
   Shows name, size, pieces, tracker, client and info_hash. Sends nothing.
2. **Run**: `ratio-master [options] <file.torrent>`.
   It runs until stopped, so start it in the background or in a terminal the user controls.
3. **Read the announce lines**:
   - `Started: tracker responded OK (interval: Ns)`: it works. The next announces follow the
     tracker's interval.
   - `tracker error: <reason>`: the tracker refused the announce (unregistered torrent, client
     not allowed, etc.). Report the reason to the user as-is.
   - `HTTP error: <code>`: the tracker URL or passkey is probably wrong.
   - `network error`: the tracker is unreachable. If the script then says
     `It doesn't work: your DNS resolves <host> to 127.0.0.1` (or `could not resolve`), the
     ISP's DNS blocks the tracker. Rerun with `--dns cloudflare`.
4. **Stop cleanly**: Ctrl+C, or `kill -TERM <pid>`. Never `kill -9`: that skips the `stopped`
   announce and leaves a ghost peer on the tracker.

## Options

| Option | Effect | Default |
|--------|--------|---------|
| `-c, --client <qbittorrent\|qb\|utorrent\|ut>` | Client to emulate | `qbittorrent` |
| `-d, --dns <system\|cloudflare\|cf\|google\|quad9\|https://…>` | Resolver for tracker requests, via DNS-over-HTTPS (needs curl 7.62+) | `system` |
| `-s, --speed <KB/s>` | Reported upload speed (randomized ±30%) | `512` |
| `--dry-run` | Show torrent info and info_hash, send nothing | |
| `--no-color` | Plain output (also honors `NO_COLOR`) | |
| `-v, --verbose` | Debug output on stderr, including the full announce URL | |

## Examples

```bash
ratio-master --dry-run ~/Downloads/file.torrent
ratio-master --dns cloudflare ~/Downloads/file.torrent
ratio-master -c ut -s 1024 --dns quad9 ~/Downloads/file.torrent
```

## Cautions

- The tracker URL contains the user's **passkey** (`/announce/<passkey>`). Never paste it into
  issues, PRs or chat. Mask it when you show output, especially with `--verbose`.
- Announces are real requests on the user's tracker account. Run only when the user asks,
  and only on trackers they are authorized to use.
