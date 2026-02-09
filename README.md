# Ratio Master

[![CI](https://github.com/maxgfr/ratio-master/actions/workflows/ci.yml/badge.svg)](https://github.com/maxgfr/ratio-master/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A torrent ratio tool that sends real HTTP announce requests to BitTorrent trackers. Parses `.torrent` files, computes info_hash, and reports incremental upload values to the tracker.

**⚠️ This tool sends real HTTP requests to trackers. Use responsibly and only on trackers you are authorized to use.**

```
  ____       _   _           __  __           _
 |  _ \ __ _| |_(_) ___     |  \/  | __ _ ___| |_ ___ _ __
 | |_) / _` | __| |/ _ \    | |\/| |/ _` / __| __/ _ \ '__|
 |  _ < (_| | |_| | (_) |   | |  | | (_| \__ \ ||  __/ |
 |_| \_\__,_|\__|_|\___/    |_|  |_|\__,_|___/\__\___|_|
```

## Features

- Parses real `.torrent` files (single-file and multi-file)
- Displays torrent metadata (name, size, pieces, tracker, comment)
- Computes info_hash in pure shell (no Python dependency)
- Sends real HTTP announces to the tracker (`started`, regular updates, `stopped`)
- Reports incremental upload values with configurable speed
- Displays live status: uploaded, ratio, speed, elapsed time, next announce
- Works on **Linux** and **macOS**
- Pure shell implementation with minimal dependencies
- Respects the [NO_COLOR](https://no-color.org/) standard

## Installation

### Via Homebrew (recommended)

```bash
# Install from tap
brew install maxgfr/tap/ratio-master

# Run
ratio-master my-file.torrent
```

### Manual installation

```bash
# Clone the repository
git clone https://github.com/maxgfr/ratio-master.git
cd ratio-master

# Make the script executable
chmod +x ratio-master.sh

# Optionally, add it to your PATH
ln -s "$(pwd)/ratio-master.sh" /usr/local/bin/ratio-master
```

### Requirements

- **bash** 4.0+
- **curl** (for HTTP requests to tracker)
- **shasum** or **openssl** (for SHA1 computation of info_hash)
- **awk** (included on all Unix systems)

## Usage

```
ratio-master.sh [OPTIONS] <file.torrent>
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-s, --speed <KB/s>` | Upload speed in KB/s | `512` |
| `--dry-run` | Show torrent info and info_hash without sending announces | - |
| `--no-color` | Disable colored output | - |
| `-v, --verbose` | Enable debug output | - |
| `-V, --version` | Show version | - |
| `-h, --help` | Show help | - |

### Examples

```bash
# Start announcing with default speed (512 KB/s, runs until Ctrl+C)
./ratio-master.sh my-file.torrent

# Custom speed (1 MB/s)
./ratio-master.sh --speed 1024 my-file.torrent

# Inspect torrent metadata and info_hash only
./ratio-master.sh --dry-run my-file.torrent
```

### Example output

```
  TORRENT FILE
  Name:          Ratio-Master-Test-File
  Size:          100 MB
  Pieces:        400 (256 KB/piece)
  Tracker:       http://tracker.example.com:8080/announce

  ANNOUNCE PARAMETERS
  Speed:            512 KB/s
  Mode:             Announce (Ctrl+C to stop)

  STARTING ANNOUNCES
  (Ctrl+C to stop)

  Tracker responded OK (interval: 1800s)

  5 MB uploaded | ratio 0.05 | 512 KB/s | 10s elapsed | next announce in 29m50s

  ^C

  ANNOUNCE STOPPED (Ctrl+C)

  RESULTS
  Uploaded:      5 MB
  Duration:      10s
  Torrent size:  100 MB
  Reported ratio: 0.05
  Status:        Ratio below 1.0
```

## Understanding Ratio

```
Ratio = Uploaded / Downloaded
```

| Ratio | Meaning |
|-------|---------|
| < 1.0 | You've downloaded more than you've uploaded |
| = 1.0 | You've given back as much as you received |
| > 1.0 | You're contributing more than you consume |

Tips for maintaining a good ratio on private trackers:

1. **Seed after downloading** - leave your client running
2. **Grab freeleech torrents** - download doesn't count against your ratio
3. **Use a seedbox** - if your home connection is limited

## How It Works

1. **Parse torrent file** - Extract tracker URL, torrent name, size, pieces
2. **Compute info_hash** - Pure shell bencode parser + SHA1 (via `shasum` or `openssl`)
3. **Generate peer_id** - Random peer ID in the format `-RM0100-<12 hex chars>`
4. **Send `started` announce** - Initial HTTP request with `event=started`
5. **Increment upload counter** - Simulate upload at specified speed
6. **Send periodic announces** - Regular updates based on tracker's interval
7. **Send `stopped` announce** - On Ctrl+C, send `event=stopped` before exiting

All announces include: `info_hash`, `peer_id`, `uploaded`, `downloaded`, `left`, `port`, `compact`, and optional `event`.

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core) (Bash Automated Testing System).

```bash
# Install bats
# macOS
brew install bats-core
# Ubuntu/Debian
sudo apt-get install bats

# Regenerate test fixtures (optional, already committed)
bash tests/generate-fixtures.sh

# Run tests
bats tests/ratio-master.bats
```

The test suite covers:

- Help and version output
- All error cases (missing file, invalid options, bad input)
- Torrent parsing (single-file, multi-file, minimal, large)
- All CLI options and shorthands
- `format_size` unit conversion with decimal precision
- `compute_info_hash` computation in pure shell
- Color mode and NO_COLOR compliance

## Project Structure

```
ratio-master/
├── ratio-master.sh              # Main script
├── test.torrent                 # Sample torrent file
├── tests/
│   ├── ratio-master.bats        # Test suite (33 tests)
│   ├── generate-fixtures.sh     # Generates test torrent files
│   └── fixtures/                # Test .torrent files
├── .github/
│   └── workflows/
│       └── ci.yml               # ShellCheck + tests on Ubuntu & macOS
├── LICENSE
└── README.md
```

## License

[MIT](LICENSE)
