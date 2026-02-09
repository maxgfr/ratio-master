#!/usr/bin/env bash

################################################################################
# ratio-master - Educational torrent upload simulator
#
# Usage: ratio-master.sh [OPTIONS] <file.torrent>
#
# Simulates upload progress locally to understand ratio
# on BitTorrent trackers. No actual network connection.
#
# License: MIT
################################################################################

set -euo pipefail

readonly VERSION="1.0.2"

################################################################################
# DEFAULT CONFIGURATION
################################################################################

readonly DEFAULT_UPLOAD_SIZE=$((5 * 1024 * 1024))  # 5 MB in bytes
readonly DEFAULT_SPEED=512                          # 512 KB/s
readonly PROGRESS_BAR_WIDTH=40

################################################################################
# GLOBAL VARIABLES
################################################################################

TORRENT_FILE=""
UPLOAD_SIZE=$DEFAULT_UPLOAD_SIZE
UPLOAD_SPEED=$DEFAULT_SPEED
SIMULATION_TIME=0
DRY_RUN=false
VERBOSE=false

# Respect the NO_COLOR standard (https://no-color.org/)
# Capture env var BEFORE replacing it with our internal variable
_NO_COLOR_ENV="${NO_COLOR+set}"
NO_COLOR=false

# Color variables (initialized empty for set -u)
BOLD="" DIM="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" CYAN=""

# Torrent information (filled by parse_torrent)
TORRENT_NAME=""
TORRENT_SIZE=""
TORRENT_PIECES=""
TORRENT_PIECE_LENGTH=""
TORRENT_TRACKER=""
TORRENT_COMMENT=""

################################################################################
# COLORS
################################################################################

setup_colors() {
    # If colors disabled, everything stays empty (already initialized)
    if [[ "$NO_COLOR" == true ]] || [[ ! -t 1 ]] || [[ -n "${_NO_COLOR_ENV:-}" ]]; then
        return
    fi

    # Enable colors
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    CYAN=$'\033[36m'
}

################################################################################
# SIGNAL HANDLING
################################################################################

cleanup() {
    # Restore cursor if interactive terminal
    if [[ -t 1 ]]; then
        printf '\033[?25h' 2>/dev/null || :
    fi
}

trap cleanup EXIT INT TERM HUP

################################################################################
# UTILITIES
################################################################################

error() {
    setup_colors
    echo "${RED}ERROR:${RESET} $*" >&2
    exit 1
}

verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo "${DIM}[DEBUG] $*${RESET}" >&2
    fi
}

# Unit conversion with decimal precision
format_size() {
    local bytes=$1

    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes} B"
        return
    fi

    awk -v b="$bytes" 'BEGIN {
        split("KB MB GB TB", units, " ")
        val = b
        idx = 0
        while (val >= 1024 && idx < 3) {
            val = val / 1024
            idx++
        }
        if (val == int(val)) {
            printf "%d %s\n", val, units[idx]
        } else {
            printf "%.1f %s\n", val, units[idx]
        }
    }'
}

# Seconds to readable format conversion
format_duration() {
    local seconds=$1

    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}s"
    elif [[ $seconds -lt 3600 ]]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m${secs}s"
    else
        local hours=$((seconds / 3600))
        local mins=$(( (seconds % 3600) / 60 ))
        echo "${hours}h${mins}m"
    fi
}

################################################################################
# HELP AND VERSION
################################################################################

show_version() {
    echo "ratio-master ${VERSION}"
}

show_help() {
    cat << 'EOF'
SYNOPSIS
    ratio-master.sh [OPTIONS] <file.torrent>

DESCRIPTION
    Simulates torrent upload progress locally to understand
    how ratio tracking works on BitTorrent trackers.

    This script performs NO actual network connection and does not
    communicate with any tracker. It's purely educational.

ARGUMENTS
    <file.torrent>
        Torrent file to analyze (required)

OPTIONS
    -s, --speed <KB/s>
        Simulated upload speed in kilobytes per second
        Default: 512 KB/s

    -S, --size <MB>
        Amount of upload to simulate in megabytes
        Default: 5 MB

    -t, --time <seconds>
        Simulation duration in seconds
        Speed is automatically calculated

    --dry-run
        Display information without running the simulation

    --no-color
        Disable colored output

    -v, --verbose
        Enable verbose mode for debugging

    -V, --version
        Display version

    -h, --help
        Display this help

EXAMPLES
    # Simulation with default parameters (512 KB/s, 5 MB)
    ratio-master.sh my-file.torrent

    # Simulation with custom speed (1 MB/s)
    ratio-master.sh --speed 1024 my-file.torrent

    # Simulate uploading 50 MB
    ratio-master.sh --size 50 my-file.torrent

    # 30-second simulation
    ratio-master.sh --time 30 my-file.torrent

    # Display info only
    ratio-master.sh --dry-run my-file.torrent

RATIO CALCULATION
    Ratio = Uploaded / Downloaded
    - Ratio < 1.0  : You still need to upload
    - Ratio = 1.0  : You've given back as much as you received
    - Ratio > 1.0  : You're a good community member!

NOTE
    This script is purely educational. To improve your actual
    ratio on a tracker, leave your torrents seeding after
    downloading.

EOF
}

################################################################################
# BENCODE PARSING (TORRENT FORMAT)
################################################################################

# Bencode parsing with POSIX tools only (100% bash)
parse_torrent_bash() {
    local torrent_file="$1"
    local content name="" size="" piece_length="" tracker="" comment=""

    # Read raw content as binary text
    content=$(LC_ALL=C cat "$torrent_file" 2>/dev/null)

    # Torrent name - search for "4:name" followed by length and name
    if [[ "$content" =~ 4:name([0-9]+): ]]; then
        local name_len="${BASH_REMATCH[1]}"
        local after_match="${content#*4:name"${name_len}":}"
        name="${after_match:0:$name_len}"
    else
        # Fallback: use the filename
        name="${torrent_file##*/}"
        name="${name%.torrent}"
    fi

    # Total size - two cases:
    # 1. Single file: "6:lengthi<N>e" in the info dict
    # 2. Multi-file: "5:filesl" with multiple "6:lengthi<N>e"
    if [[ "$content" =~ 5:filesl ]]; then
        # Multi-file: extract "files" section and sum
        local files_section="${content#*5:filesl}"

        # Stop at closing of files list
        if [[ "$files_section" =~ (.*[ee])4:name ]]; then
            files_section="${BASH_REMATCH[1]}"
        fi

        # Extract all "lengthi<number>e"
        local total=0
        while [[ "$files_section" =~ lengthi([0-9]+)e ]]; do
            total=$((total + BASH_REMATCH[1]))
            files_section="${files_section#*lengthi"${BASH_REMATCH[1]}"e}"
        done

        if [[ $total -gt 0 ]]; then
            size="$total"
        fi
    else
        # Single file
        if [[ "$content" =~ 6:lengthi([0-9]+)e ]]; then
            size="${BASH_REMATCH[1]}"
        fi
    fi

    # Piece length
    if [[ "$content" =~ piece\ lengthi([0-9]+)e ]]; then
        piece_length="${BASH_REMATCH[1]}"
    fi

    # Tracker
    if [[ "$content" =~ announce([0-9]+): ]]; then
        local tracker_len="${BASH_REMATCH[1]}"
        local after_announce="${content#*announce"${tracker_len}":}"
        tracker="${after_announce:0:$tracker_len}"
    fi

    # Comment
    if [[ "$content" =~ comment([0-9]+): ]]; then
        local comment_len="${BASH_REMATCH[1]}"
        local after_comment="${content#*comment"${comment_len}":}"
        comment="${after_comment:0:$comment_len}"
    fi

    # Output all at once (faster)
    printf 'NAME=%s\nSIZE=%s\nPIECE_LENGTH=%s\nTRACKER=%s\nCOMMENT=%s\n' \
        "$name" \
        "${size:-0}" \
        "${piece_length:-262144}" \
        "$tracker" \
        "$comment"
}

# Parse the torrent file
parse_torrent() {
    local torrent_file="$1"

    verbose "Parsing torrent file: $torrent_file"

    if [[ ! -f "$torrent_file" ]]; then
        error "Torrent file does not exist: $torrent_file"
    fi

    if [[ ! -r "$torrent_file" ]]; then
        error "Torrent file is not readable: $torrent_file"
    fi

    # Verify bencode signature (must start with 'd')
    local first_byte
    first_byte=$(LC_ALL=C head -c1 "$torrent_file")
    if [[ "$first_byte" != "d" ]]; then
        error "File does not appear to be a valid torrent file"
    fi

    # Parse with pure bash only
    verbose "Parsing bencode with pure bash"
    local parsed
    parsed=$(parse_torrent_bash "$torrent_file")

    # Extract values via parameter expansion (0 subshell)
    local line
    while IFS= read -r line; do
        case "$line" in
            NAME=*)         TORRENT_NAME="${line#NAME=}" ;;
            SIZE=*)         TORRENT_SIZE="${line#SIZE=}" ;;
            PIECE_LENGTH=*) TORRENT_PIECE_LENGTH="${line#PIECE_LENGTH=}" ;;
            TRACKER=*)      TORRENT_TRACKER="${line#TRACKER=}" ;;
            COMMENT=*)      TORRENT_COMMENT="${line#COMMENT=}" ;;
        esac
    done <<< "$parsed"

    # Default values if empty
    if [[ -z "$TORRENT_NAME" ]]; then
        TORRENT_NAME="${torrent_file##*/}"
        TORRENT_NAME="${TORRENT_NAME%.torrent}"
    fi
    if [[ -z "$TORRENT_PIECE_LENGTH" ]]; then
        TORRENT_PIECE_LENGTH=262144
    fi

    # Calculate number of pieces
    if [[ "$TORRENT_SIZE" =~ ^[0-9]+$ && "$TORRENT_SIZE" -gt 0 ]]; then
        TORRENT_PIECES=$(( (TORRENT_SIZE + TORRENT_PIECE_LENGTH - 1) / TORRENT_PIECE_LENGTH ))
    else
        TORRENT_SIZE="0"
        TORRENT_PIECES="?"
    fi

    verbose "Name: $TORRENT_NAME"
    verbose "Size: $TORRENT_SIZE bytes"
    verbose "Pieces: $TORRENT_PIECES"
    verbose "Tracker: $TORRENT_TRACKER"
}

################################################################################
# INFORMATION DISPLAY
################################################################################

display_torrent_info() {
    echo "${BOLD}${CYAN}"
    echo "  ____       _   _           __  __           _            "
    echo " |  _ \\ __ _| |_(_) ___     |  \\/  | __ _ ___| |_ ___ _ __ "
    echo " | |_) / _\` | __| |/ _ \\    | |\\/| |/ _\` / __| __/ _ \\ '__|"
    echo " |  _ < (_| | |_| | (_) |   | |  | | (_| \\__ \\ ||  __/ |   "
    echo " |_| \\_\\__,_|\\__|_|\\___/    |_|  |_|\\__,_|___/\\__\\___|_|   "
    echo "${RESET}"
    echo ""
    echo "${BOLD}  TORRENT FILE${RESET}"
    echo "  ${DIM}Name:${RESET}          ${TORRENT_NAME}"

    if [[ "$TORRENT_SIZE" != "0" ]]; then
        echo "  ${DIM}Size:${RESET}          $(format_size "$TORRENT_SIZE")"
        echo "  ${DIM}Pieces:${RESET}        ${TORRENT_PIECES} ($(format_size "$TORRENT_PIECE_LENGTH")/piece)"
    else
        echo "  ${DIM}Size:${RESET}          Unknown"
    fi

    if [[ -n "$TORRENT_TRACKER" ]]; then
        echo "  ${DIM}Tracker:${RESET}       ${TORRENT_TRACKER}"
    fi

    if [[ -n "$TORRENT_COMMENT" ]]; then
        echo "  ${DIM}Comment:${RESET}       ${TORRENT_COMMENT}"
    fi

    echo ""
    echo "${BOLD}  SIMULATION PARAMETERS${RESET}"
    echo "  ${DIM}Simulated upload:${RESET} $(format_size "$UPLOAD_SIZE")"
    echo "  ${DIM}Speed:${RESET}            ${UPLOAD_SPEED} KB/s"

    # Calculate estimated duration
    local speed_bytes=$((UPLOAD_SPEED * 1024))
    if [[ $speed_bytes -gt 0 ]]; then
        local estimated_seconds=$((UPLOAD_SIZE / speed_bytes))
        echo "  ${DIM}Estimated time:${RESET}   $(format_duration "$estimated_seconds")"
    fi

    echo ""
}

################################################################################
# PROGRESS BAR
################################################################################

show_progress() {
    local current=$1
    local total=$2
    local speed=$3

    # Percentage
    local percent=0
    if [[ $total -gt 0 ]]; then
        percent=$((current * 100 / total))
    fi

    # Visual bar
    local filled=$((percent * PROGRESS_BAR_WIDTH / 100))
    local empty=$((PROGRESS_BAR_WIDTH - filled))

    local bar=""
    bar+="${GREEN}"
    for ((i = 0; i < filled; i++)); do
        bar+="█"
    done
    bar+="${DIM}"
    for ((i = 0; i < empty; i++)); do
        bar+="░"
    done
    bar+="${RESET}"

    # ETA
    local eta_str=""
    if [[ $current -gt 0 && $speed -gt 0 ]]; then
        local remaining_bytes=$((total - current))
        local speed_bytes=$((speed * 1024))
        local eta_seconds=$((remaining_bytes / speed_bytes))
        eta_str="ETA $(format_duration $eta_seconds)"
    else
        eta_str="ETA --"
    fi

    # Display on one line (clear line to avoid artifacts)
    printf '\r\033[K  [%s] %3d%% | %s / %s | %s KB/s | %s ' \
        "$bar" "$percent" \
        "$(format_size "$current")" "$(format_size "$total")" \
        "$speed" "$eta_str"
}

################################################################################
# UPLOAD SIMULATION
################################################################################

simulate_upload() {
    echo "  ${BOLD}${BLUE}STARTING SIMULATION${RESET}"
    echo "  ${DIM}(No data is actually sent)${RESET}"
    echo ""

    local uploaded=0
    local speed_bytes=$((UPLOAD_SPEED * 1024))

    # Detect fractional sleep support
    local sleep_interval=0.1
    local updates_per_sec=10
    if ! sleep 0.1 2>/dev/null; then
        sleep_interval=1
        updates_per_sec=1
    fi

    local chunk_size=$((speed_bytes / updates_per_sec))
    # Minimum chunk of 1 byte to avoid infinite loop
    [[ $chunk_size -lt 1 ]] && chunk_size=1

    # Hide cursor during simulation (terminal only)
    [[ -t 1 ]] && printf '\033[?25l'

    while [[ $uploaded -lt $UPLOAD_SIZE ]]; do
        local remaining=$((UPLOAD_SIZE - uploaded))
        local current_chunk=$((chunk_size < remaining ? chunk_size : remaining))
        uploaded=$((uploaded + current_chunk))

        show_progress "$uploaded" "$UPLOAD_SIZE" "$UPLOAD_SPEED"

        sleep "$sleep_interval"
    done

    # Final display at 100%
    show_progress "$UPLOAD_SIZE" "$UPLOAD_SIZE" "$UPLOAD_SPEED"
    [[ -t 1 ]] && printf '\033[?25h'  # Restore cursor
    echo ""
    echo ""

    # Calculate simulated ratio
    local download_size
    if [[ "$TORRENT_SIZE" != "0" ]]; then
        download_size=$TORRENT_SIZE
    else
        download_size=$((1024 * 1024 * 1024))  # 1 GB default
    fi

    local ratio
    ratio=$(awk -v up="$UPLOAD_SIZE" -v down="$download_size" 'BEGIN { printf "%.2f", up / down }')

    echo "  ${BOLD}${GREEN}SIMULATION COMPLETE${RESET}"
    echo ""
    echo "  ${BOLD}RESULTS${RESET}"
    echo "  ${DIM}Uploaded:${RESET}      $(format_size "$UPLOAD_SIZE")"

    if [[ "$TORRENT_SIZE" != "0" ]]; then
        echo "  ${DIM}Torrent size:${RESET}  $(format_size "$download_size")"
    fi

    echo "  ${DIM}Simulated ratio:${RESET} ${BOLD}${ratio}${RESET}"

    local ratio_status
    ratio_status=$(awk -v r="$ratio" 'BEGIN { print (r < 1.0) ? "low" : (r > 1.0) ? "high" : "equal" }')

    case "$ratio_status" in
        low)
            echo "  ${DIM}Status:${RESET}        ${YELLOW}Ratio below 1.0${RESET}"
            ;;
        equal)
            echo "  ${DIM}Status:${RESET}        ${GREEN}Ratio equal to 1.0${RESET}"
            ;;
        high)
            echo "  ${DIM}Status:${RESET}        ${GREEN}Ratio above 1.0 - Excellent!${RESET}"
            ;;
    esac

    echo ""
    echo "  ${BOLD}TIP${RESET}"
    echo "  To maintain a good ratio on a real tracker:"
    echo "  1. Leave your torrents seeding after download"
    echo "  2. Prioritize new torrents (freeleech)"
    echo "  3. Use a seedbox if your connection is limited"
    echo ""
}

################################################################################
# ARGUMENT PARSING
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -V|--version)
                show_version
                exit 0
                ;;
            -s|--speed)
                if [[ -z "${2:-}" ]]; then
                    error "Option --speed requires a value"
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    error "Speed must be a positive integer"
                fi
                if [[ "$2" -eq 0 ]]; then
                    error "Speed cannot be 0"
                fi
                UPLOAD_SPEED="$2"
                shift 2
                ;;
            -S|--size)
                if [[ -z "${2:-}" ]]; then
                    error "Option --size requires a value (in MB)"
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    error "Size must be a positive integer"
                fi
                if [[ "$2" -eq 0 ]]; then
                    error "Size cannot be 0"
                fi
                if [[ "$2" -gt 8388608 ]]; then
                    error "Size cannot exceed 8388608 MB (8 TB)"
                fi
                UPLOAD_SIZE=$(($2 * 1024 * 1024))
                shift 2
                ;;
            -t|--time)
                if [[ -z "${2:-}" ]]; then
                    error "Option --time requires a value"
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    error "Time must be a positive integer"
                fi
                if [[ "$2" -eq 0 ]]; then
                    error "Time cannot be 0"
                fi
                SIMULATION_TIME="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -*)
                error "Unknown option: $1 (use -h for help)"
                ;;
            *)
                if [[ -n "$TORRENT_FILE" ]]; then
                    error "Too many files specified. Only one .torrent file expected."
                fi
                TORRENT_FILE="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$TORRENT_FILE" ]]; then
        error "No torrent file specified. Use -h for help."
    fi

    if [[ ! "$TORRENT_FILE" =~ \.torrent$ ]]; then
        error "File must have .torrent extension"
    fi

    # If --time is specified, recalculate speed
    if [[ $SIMULATION_TIME -gt 0 ]]; then
        UPLOAD_SPEED=$((UPLOAD_SIZE / SIMULATION_TIME / 1024))
        if [[ $UPLOAD_SPEED -lt 1 ]]; then
            UPLOAD_SPEED=1
        fi
    fi
}

################################################################################
# ENTRY POINT
################################################################################

main() {
    setup_colors
    parse_arguments "$@"
    parse_torrent "$TORRENT_FILE"
    display_torrent_info

    if [[ "$DRY_RUN" == true ]]; then
        echo "  ${DIM}DRY-RUN MODE - No simulation performed${RESET}"
        exit 0
    fi

    simulate_upload
}

main "$@"
