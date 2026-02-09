# Ratio Master

[![CI](https://github.com/maxgfr/ratio-master/actions/workflows/ci.yml/badge.svg)](https://github.com/maxgfr/ratio-master/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A local torrent upload simulator for educational purposes. Parses `.torrent` files and simulates upload progress to help understand how BitTorrent ratio tracking works.

**No data is ever sent over the network.** This is a purely local simulation.

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
- Simulates upload with a live progress bar and ETA
- Calculates the resulting ratio
- Works on **Linux** and **macOS**
- Zero dependencies beyond `bash` and `awk` (100% pure bash implementation)
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
- **awk** (included on all Unix systems)

## Usage

```
ratio-master.sh [OPTIONS] <file.torrent>
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-s, --speed <KB/s>` | Simulated upload speed in KB/s | `512` |
| `-S, --size <MB>` | Amount of upload to simulate in MB | `5` |
| `-t, --time <seconds>` | Simulation duration (speed auto-calculated) | - |
| `--dry-run` | Show torrent info without running the simulation | - |
| `--no-color` | Disable colored output | - |
| `-v, --verbose` | Enable debug output | - |
| `-V, --version` | Show version | - |
| `-h, --help` | Show help | - |

### Examples

```bash
# Basic simulation (5 MB at 512 KB/s)
./ratio-master.sh my-file.torrent

# Custom speed (1 MB/s)
./ratio-master.sh --speed 1024 my-file.torrent

# Simulate uploading 50 MB
./ratio-master.sh --size 50 my-file.torrent

# Fixed duration (30 seconds, speed auto-calculated)
./ratio-master.sh --time 30 my-file.torrent

# Inspect torrent metadata only
./ratio-master.sh --dry-run my-file.torrent
```

### Example output

```
  FICHIER TORRENT
  Nom:           Ratio-Master-Test-File
  Taille:        100 Mo
  Pieces:        400 (256 Ko/piece)
  Tracker:       http://tracker.example.com:8080/announce

  PARAMETRES DE SIMULATION
  Upload simule:   5 Mo
  Vitesse:         512 KB/s
  Duree estimee:   10s

  [████████████████████████████████████████] 100% | 5 Mo / 5 Mo | 512 KB/s | ETA 0s

  RESULTATS
  Uploade:       5 Mo
  Taille torrent: 100 Mo
  Ratio simule:  0.05
  Statut:        Ratio inferieur a 1.0
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
- Color mode and NO_COLOR compliance

## Project Structure

```
ratio-master/
├── ratio-master.sh              # Main script
├── test.torrent                 # Sample torrent file
├── tests/
│   ├── ratio-master.bats        # Test suite (39 tests)
│   └── generate-fixtures.sh     # Generates test torrent files
├── .github/
│   └── workflows/
│       └── ci.yml               # ShellCheck + tests on Ubuntu & macOS
├── LICENSE
└── README.md
```

## License

[MIT](LICENSE)
