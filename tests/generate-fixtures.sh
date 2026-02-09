#!/usr/bin/env bash
# Generate test fixture torrent files (100% bash, no Python)

set -euo pipefail

FIXTURES_DIR="$(cd "$(dirname "$0")" && pwd)/fixtures"
mkdir -p "$FIXTURES_DIR"

################################################################################
# Bencode encoding functions
################################################################################

# Encode a string: <length>:<data>
bencode_str() {
    local str="$1"
    printf '%d:%s' "${#str}" "$str"
}

# Encode an integer: i<number>e
bencode_int() {
    printf 'i%de' "$1"
}

# Encode raw bytes as a bencode string (length prefix + raw data)
# Usage: bencode_raw_str <length> <repeated_char>
bencode_raw_str() {
    local len="$1"
    local char="$2"
    printf '%d:' "$len"
    local i
    for ((i = 0; i < len; i++)); do
        printf '%s' "$char"
    done
}

# Write a complete torrent dict to a file
# Takes pairs as: key1 value1 key2 value2 ...
# Keys MUST be pre-sorted alphabetically (bencode requirement)
write_dict() {
    printf 'd'
    while [[ $# -ge 2 ]]; do
        bencode_str "$1"
        printf '%s' "$2"
        shift 2
    done
    printf 'e'
}

################################################################################
# Generate fixtures
################################################################################

# 1. Simple single-file torrent (100 Mo)
generate_simple() {
    local info
    info=$(write_dict \
        "length" "$(bencode_int 104857600)" \
        "name" "$(bencode_str 'Test-File')" \
        "piece length" "$(bencode_int 262144)" \
        "pieces" "$(bencode_raw_str 20 'a')")

    write_dict \
        "announce" "$(bencode_str 'http://tracker.example.com/announce')" \
        "comment" "$(bencode_str 'Test torrent')" \
        "info" "$info"
}

# 2. Multi-file torrent (50 Mo + 25 Mo = 75 Mo)
generate_multifile() {
    local file1 file2 files_list info

    file1=$(write_dict \
        "length" "$(bencode_int 52428800)" \
        "path" "l$(bencode_str 'file1.txt')e")

    file2=$(write_dict \
        "length" "$(bencode_int 26214400)" \
        "path" "l$(bencode_str 'subdir')$(bencode_str 'file2.txt')e")

    files_list="l${file1}${file2}e"

    info=$(write_dict \
        "files" "$files_list" \
        "name" "$(bencode_str 'Multi-File-Torrent')" \
        "piece length" "$(bencode_int 524288)" \
        "pieces" "$(bencode_raw_str 20 'b')")

    write_dict \
        "announce" "$(bencode_str 'http://tracker.example.com/announce')" \
        "info" "$info"
}

# 3. Minimal torrent (1 Ko)
generate_minimal() {
    local info
    info=$(write_dict \
        "length" "$(bencode_int 1024)" \
        "name" "$(bencode_str 'tiny')" \
        "piece length" "$(bencode_int 16384)" \
        "pieces" "$(bencode_raw_str 20 'c')")

    write_dict \
        "announce" "$(bencode_str 'http://example.com/announce')" \
        "info" "$info"
}

# 4. Large torrent (10 Go, multiple tracker fields)
generate_large() {
    local info announce_list

    info=$(write_dict \
        "length" "$(bencode_int 10737418240)" \
        "name" "$(bencode_str 'Big-File-10Go')" \
        "piece length" "$(bencode_int 4194304)" \
        "pieces" "$(bencode_raw_str 20 'd')")

    announce_list="l"
    announce_list+="l$(bencode_str 'http://private.tracker.org/announce')e"
    announce_list+="l$(bencode_str 'http://backup.tracker.org/announce')e"
    announce_list+="e"

    write_dict \
        "announce" "$(bencode_str 'http://private.tracker.org/announce')" \
        "announce-list" "$announce_list" \
        "comment" "$(bencode_str 'A large file for testing')" \
        "created by" "$(bencode_str 'ratio-master-tests')" \
        "encoding" "$(bencode_str 'UTF-8')" \
        "info" "$info"
}

# 5. Invalid file (not a torrent)
generate_invalid() {
    printf 'This is not a torrent file'
}

################################################################################
# Main
################################################################################

generate_simple    > "$FIXTURES_DIR/simple.torrent"
generate_multifile > "$FIXTURES_DIR/multifile.torrent"
generate_minimal   > "$FIXTURES_DIR/minimal.torrent"
generate_large     > "$FIXTURES_DIR/large.torrent"
generate_invalid   > "$FIXTURES_DIR/invalid.torrent"

echo "All fixtures generated successfully (pure bash)"
