#!/usr/bin/env bats

# ratio-master.sh test suite
# Requires: bats-core (https://github.com/bats-core/bats-core)

SCRIPT="$BATS_TEST_DIRNAME/../ratio-master.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

################################################################################
# HELP & VERSION
################################################################################

@test "shows help with -h" {
    run "$SCRIPT" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"SYNOPSIS"* ]]
    [[ "$output" == *"ratio-master.sh"* ]]
}

@test "shows help with --help" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"DESCRIPTION"* ]]
}

################################################################################
# ERROR HANDLING - MISSING ARGUMENTS
################################################################################

@test "fails without arguments" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No torrent file"* ]]
}

@test "fails with non-.torrent extension" {
    run "$SCRIPT" file.txt
    [ "$status" -eq 1 ]
    [[ "$output" == *".torrent extension"* ]]
}

@test "fails with nonexistent file" {
    run "$SCRIPT" nonexistent.torrent
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "fails with multiple files" {
    run "$SCRIPT" a.torrent b.torrent
    [ "$status" -eq 1 ]
    [[ "$output" == *"Too many files"* ]]
}

@test "fails with unknown option" {
    run "$SCRIPT" --unknown test.torrent
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "fails with removed --size option" {
    run "$SCRIPT" --size 50 "$FIXTURES/simple.torrent"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "fails with removed --time option" {
    run "$SCRIPT" --time 60 "$FIXTURES/simple.torrent"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}

################################################################################
# ERROR HANDLING - OPTION VALIDATION
################################################################################

@test "fails with --speed without value" {
    run "$SCRIPT" --speed
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a value"* ]]
}

@test "fails with --speed non-numeric" {
    run "$SCRIPT" --speed abc "$FIXTURES/simple.torrent"
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "fails with --speed 0" {
    run "$SCRIPT" --speed 0 "$FIXTURES/simple.torrent"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot be 0"* ]]
}


################################################################################
# INVALID TORRENT
################################################################################

@test "fails with invalid torrent file" {
    run "$SCRIPT" --dry-run "$FIXTURES/invalid.torrent"
    [ "$status" -eq 1 ]
    [[ "$output" == *"valid torrent file"* ]]
}

################################################################################
# DRY-RUN MODE
################################################################################

@test "dry-run shows torrent info without announce" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TORRENT FILE"* ]]
    [[ "$output" == *"Test-File"* ]]
    [[ "$output" == *"100 MB"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "dry-run shows tracker info" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tracker.example.com"* ]]
}

@test "dry-run shows comment" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test torrent"* ]]
}

@test "dry-run shows announce mode" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Seed"* ]]
    [[ "$output" == *"Ctrl+C"* ]]
}

@test "dry-run shows info_hash" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"info_hash"* ]]
    # info_hash should be 40 hex chars
    [[ "$output" =~ [0-9a-f]{40} ]]
}

################################################################################
# TORRENT PARSING
################################################################################

@test "parses single-file torrent correctly" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test-File"* ]]
    [[ "$output" == *"100 MB"* ]]
}

@test "parses multi-file torrent correctly" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/multifile.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Multi-File-Torrent"* ]]
    # 52428800 + 26214400 = 78643200 = 75 MB
    [[ "$output" == *"75 MB"* ]]
}

@test "parses minimal torrent correctly" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/minimal.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tiny"* ]]
    [[ "$output" == *"1 KB"* ]]
}

@test "parses large torrent metadata correctly" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/large.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Big-File-10Go"* ]]
    [[ "$output" == *"10 GB"* ]]
}

################################################################################
# OPTIONS
################################################################################

@test "accepts --speed option" {
    run "$SCRIPT" --dry-run --no-color --speed 1024 "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1024 KB/s"* ]]
}

@test "accepts -s shorthand" {
    run "$SCRIPT" --dry-run --no-color -s 256 "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"256 KB/s"* ]]
}

@test "accepts --verbose option" {
    run "$SCRIPT" --dry-run --no-color --verbose "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DEBUG]"* ]] || [[ "$stderr" == *"[DEBUG]"* ]]
}

@test "torrent file can come before options" {
    run "$SCRIPT" "$FIXTURES/simple.torrent" --dry-run --no-color
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test-File"* ]]
}

################################################################################
# FORMAT SIZE FUNCTION
################################################################################

@test "format_size handles bytes" {
    run bash -c "
        format_size() {
            local bytes=\$1
            if [[ \$bytes -lt 1024 ]]; then echo \"\${bytes} B\"; return; fi
            awk -v b=\"\$bytes\" 'BEGIN {
                split(\"KB MB GB TB\", units, \" \")
                val = b; idx = 0
                while (val >= 1024 && idx < 3) { val = val / 1024; idx++ }
                if (val == int(val)) { printf \"%d %s\n\", val, units[idx] }
                else { printf \"%.1f %s\n\", val, units[idx] }
            }'
        }
        format_size 512
    "
    [[ "$output" == "512 B" ]]
}

@test "format_size handles kilobytes" {
    run bash -c "
        format_size() {
            local bytes=\$1
            if [[ \$bytes -lt 1024 ]]; then echo \"\${bytes} B\"; return; fi
            awk -v b=\"\$bytes\" 'BEGIN {
                split(\"KB MB GB TB\", units, \" \")
                val = b; idx = 0
                while (val >= 1024 && idx < 3) { val = val / 1024; idx++ }
                if (val == int(val)) { printf \"%d %s\n\", val, units[idx] }
                else { printf \"%.1f %s\n\", val, units[idx] }
            }'
        }
        format_size 1024
    "
    [[ "$output" == "1 KB" ]]
}

@test "format_size handles decimal precision" {
    run bash -c "
        format_size() {
            local bytes=\$1
            if [[ \$bytes -lt 1024 ]]; then echo \"\${bytes} B\"; return; fi
            awk -v b=\"\$bytes\" 'BEGIN {
                split(\"KB MB GB TB\", units, \" \")
                val = b; idx = 0
                while (val >= 1024 && idx < 3) { val = val / 1024; idx++ }
                if (val == int(val)) { printf \"%d %s\n\", val, units[idx] }
                else { printf \"%.1f %s\n\", val, units[idx] }
            }'
        }
        format_size 1536
    "
    [[ "$output" == "1.5 KB" ]]
}

@test "format_size handles megabytes" {
    run bash -c "
        format_size() {
            local bytes=\$1
            if [[ \$bytes -lt 1024 ]]; then echo \"\${bytes} B\"; return; fi
            awk -v b=\"\$bytes\" 'BEGIN {
                split(\"KB MB GB TB\", units, \" \")
                val = b; idx = 0
                while (val >= 1024 && idx < 3) { val = val / 1024; idx++ }
                if (val == int(val)) { printf \"%d %s\n\", val, units[idx] }
                else { printf \"%.1f %s\n\", val, units[idx] }
            }'
        }
        format_size 5242880
    "
    [[ "$output" == "5 MB" ]]
}

@test "format_size handles gigabytes" {
    run bash -c "
        format_size() {
            local bytes=\$1
            if [[ \$bytes -lt 1024 ]]; then echo \"\${bytes} B\"; return; fi
            awk -v b=\"\$bytes\" 'BEGIN {
                split(\"KB MB GB TB\", units, \" \")
                val = b; idx = 0
                while (val >= 1024 && idx < 3) { val = val / 1024; idx++ }
                if (val == int(val)) { printf \"%d %s\n\", val, units[idx] }
                else { printf \"%.1f %s\n\", val, units[idx] }
            }'
        }
        format_size 10737418240
    "
    [[ "$output" == "10 GB" ]]
}

################################################################################
# NO-COLOR MODE
################################################################################

@test "no-color mode suppresses ANSI codes" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    # Should not contain escape codes
    [[ "$output" != *$'\033'* ]]
}

################################################################################
# CLIENT SELECTION
################################################################################

@test "defaults to qbittorrent client" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"qBittorrent 4.6.2"* ]]
}

@test "--client qbittorrent selects qBittorrent" {
    run "$SCRIPT" --dry-run --no-color --client qbittorrent "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"qBittorrent 4.6.2"* ]]
}

@test "--client utorrent selects uTorrent" {
    run "$SCRIPT" --dry-run --no-color --client utorrent "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"uTorrent 3.3.2"* ]]
}

@test "-c shorthand works" {
    run "$SCRIPT" --dry-run --no-color -c utorrent "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"uTorrent 3.3.2"* ]]
}

@test "--client is case-insensitive" {
    run "$SCRIPT" --dry-run --no-color --client QBITTORRENT "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"qBittorrent 4.6.2"* ]]
}

@test "--client accepts short alias qb" {
    run "$SCRIPT" --dry-run --no-color --client qb "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"qBittorrent 4.6.2"* ]]
}

@test "--client accepts short alias ut" {
    run "$SCRIPT" --dry-run --no-color --client ut "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"uTorrent 3.3.2"* ]]
}

@test "--client without value fails" {
    run "$SCRIPT" --client
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a value"* ]]
}

@test "--client with unknown client fails" {
    run "$SCRIPT" --client deluge "$FIXTURES/simple.torrent"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown client"* ]]
}

@test "help text shows --client option" {
    run "$SCRIPT" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"--client"* ]]
}

################################################################################
# BANNER
################################################################################

@test "displays ASCII banner" {
    run "$SCRIPT" --dry-run --no-color "$FIXTURES/simple.torrent"
    [ "$status" -eq 0 ]
    # ASCII art banner contains these patterns
    [[ "$output" == *"____"* ]]
    [[ "$output" == *"|_|"* ]]
}
