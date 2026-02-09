#!/usr/bin/env bash

################################################################################
# ratio-master - Torrent ratio tool via real HTTP tracker announces
#
# Usage: ratio-master.sh [OPTIONS] <file.torrent>
#
# Sends real HTTP announce requests to the tracker extracted from
# the .torrent file, reporting incremental upload values.
#
# License: MIT
################################################################################

set -euo pipefail

readonly VERSION="1.1.0"

################################################################################
# DEFAULT CONFIGURATION
################################################################################

readonly DEFAULT_SPEED=512                          # 512 KB/s

################################################################################
# GLOBAL VARIABLES
################################################################################

TORRENT_FILE=""
UPLOAD_SPEED=$DEFAULT_SPEED
UPLOADED=0
DOWNLOADED=0
SIMULATION_START=0
DRY_RUN=false
VERBOSE=false

INFO_HASH=""              # info_hash URL-encoded (%xx%xx...)
INFO_HASH_HEX=""          # info_hash in hex (for display)
PEER_ID=""                # peer_id URL-encoded
ANNOUNCE_INTERVAL=1800    # interval between announces (updated by tracker)
LAST_ANNOUNCE_TIME=0      # epoch of last successful announce

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
# DEPENDENCY CHECK
################################################################################

check_dependencies() {
    local missing=()

    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    # Need either shasum or openssl for SHA1
    if ! command -v shasum &>/dev/null && ! command -v openssl &>/dev/null; then
        missing+=("shasum or openssl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}"
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
    Sends real HTTP announce requests to the tracker extracted
    from the .torrent file, reporting incremental upload values.

ARGUMENTS
    <file.torrent>
        Torrent file to analyze (required)

OPTIONS
    -s, --speed <KB/s>
        Upload speed in kilobytes per second
        Default: 512 KB/s

    --dry-run
        Display information without sending any announce

    --no-color
        Disable colored output

    -v, --verbose
        Enable verbose mode for debugging

    -V, --version
        Display version

    -h, --help
        Display this help

EXAMPLES
    # Announce with default speed (512 KB/s), runs until Ctrl+C
    ratio-master.sh my-file.torrent

    # Announce with custom speed (1 MB/s)
    ratio-master.sh --speed 1024 my-file.torrent

    # Display info only
    ratio-master.sh --dry-run my-file.torrent

RATIO CALCULATION
    Ratio = Uploaded / Downloaded
    - Ratio < 1.0  : You still need to upload
    - Ratio = 1.0  : You've given back as much as you received
    - Ratio > 1.0  : You're a good community member!

NOTE
    This tool sends real HTTP requests to the tracker.
    Use responsibly and only on trackers you are authorized to use.

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
# INFO HASH & PEER ID
################################################################################

compute_info_hash() {
    local torrent_file="$1"

    verbose "Computing info_hash (pure shell)"

    # Read file as hex bytes (space-separated, lowercase)
    local hex_bytes
    hex_bytes=$(od -An -tx1 -v "$torrent_file" | tr -d '\n ')

    # Find "4:info" in hex: 34 3a 69 6e 66 6f
    local needle="343a696e666f"
    local prefix="${hex_bytes%%"$needle"*}"

    if [[ "${#prefix}" -eq "${#hex_bytes}" ]]; then
        error "No info dict found in torrent file"
    fi

    # Byte offset where the info value starts (after "4:info" = 6 bytes)
    local info_start=$(( ${#prefix} / 2 + 6 ))

    # Parse bencode from hex to find the end of the info dict
    # We work on the hex string, 2 hex chars = 1 byte
    local pos=$((info_start * 2))

    # Recursive bencode end finder
    _skip_bencode_value() {
        local p=$1
        local ch="${hex_bytes:$p:2}"

        case "$ch" in
            64|6c)  # 'd' (0x64) or 'l' (0x6c) — dict or list
                p=$((p + 2))
                while [[ "${hex_bytes:$p:2}" != "65" ]]; do  # not 'e' (0x65)
                    p=$(_skip_bencode_value "$p")
                done
                echo $((p + 2))  # skip the 'e'
                ;;
            69)  # 'i' (0x69) — integer i<digits>e
                p=$((p + 2))
                while [[ "${hex_bytes:$p:2}" != "65" ]]; do
                    p=$((p + 2))
                done
                echo $((p + 2))  # skip the 'e'
                ;;
            3[0-9]|[0-9][0-9])  # digit — string length prefix
                # Collect ASCII digits until we hit ':' (0x3a)
                local num_str=""
                while [[ "${hex_bytes:$p:2}" != "3a" ]]; do
                    # Convert hex to ASCII char
                    local byte_val=$((16#${hex_bytes:$p:2}))
                    if [[ $byte_val -ge 48 && $byte_val -le 57 ]]; then
                        num_str+=$(printf '%b' "\\$(printf '%03o' "$byte_val")")
                    else
                        break
                    fi
                    p=$((p + 2))
                done
                p=$((p + 2))  # skip ':'
                local str_len=$((num_str))
                echo $((p + str_len * 2))
                ;;
            *)
                error "Unexpected bencode byte at offset $((p/2)): 0x$ch"
                ;;
        esac
    }

    local end_pos
    end_pos=$(_skip_bencode_value "$pos")
    local info_end=$((end_pos / 2))
    local info_len=$((info_end - info_start))

    verbose "Info dict: offset=$info_start length=$info_len"

    # Extract info dict bytes and compute SHA1
    local sha1_hex
    if command -v shasum &>/dev/null; then
        sha1_hex=$(dd if="$torrent_file" bs=1 skip="$info_start" count="$info_len" 2>/dev/null | shasum -a 1 | cut -d' ' -f1)
    else
        sha1_hex=$(dd if="$torrent_file" bs=1 skip="$info_start" count="$info_len" 2>/dev/null | openssl dgst -sha1 -r | cut -d' ' -f1)
    fi

    INFO_HASH_HEX="$sha1_hex"

    # URL-encode: %xx for each byte of the SHA1 digest
    INFO_HASH=""
    local i
    for (( i=0; i<${#sha1_hex}; i+=2 )); do
        INFO_HASH+="%${sha1_hex:$i:2}"
    done

    verbose "info_hash (hex): $INFO_HASH_HEX"
    verbose "info_hash (url): $INFO_HASH"
}

generate_peer_id() {
    local random_part
    random_part=$(LC_ALL=C head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 12)

    # Format: -RM0100-<12 random chars>
    local raw="-RM0100-${random_part}"

    # URL-encode: encode each byte
    PEER_ID=""
    local i ch
    for (( i=0; i<${#raw}; i++ )); do
        ch="${raw:$i:1}"
        case "$ch" in
            [a-zA-Z0-9._~])
                PEER_ID+="$ch"
                ;;
            *)
                PEER_ID+=$(printf '%%%02x' "'$ch")
                ;;
        esac
    done

    verbose "peer_id (raw): $raw"
    verbose "peer_id (url): $PEER_ID"
}

################################################################################
# TRACKER COMMUNICATION
################################################################################

send_announce() {
    local event="${1:-}"

    if [[ -z "$TORRENT_TRACKER" ]]; then
        verbose "No tracker URL, skipping announce"
        return 1
    fi

    # Build query parameters
    local url="${TORRENT_TRACKER}"
    url+="?info_hash=${INFO_HASH}"
    url+="&peer_id=${PEER_ID}"
    url+="&port=6881"
    url+="&uploaded=${UPLOADED}"
    url+="&downloaded=${DOWNLOADED}"
    url+="&left=0"
    url+="&compact=1"

    if [[ -n "$event" ]]; then
        url+="&event=${event}"
    fi

    verbose "Announce URL: $url"

    local tmpfile
    tmpfile=$(mktemp)

    local http_code
    http_code=$(curl --silent --max-time 30 --output "$tmpfile" --write-out '%{http_code}' "$url" 2>/dev/null) || {
        rm -f "$tmpfile"
        verbose "Network error during announce"
        echo "NETWORK_ERROR"
        return 0
    }

    if [[ "$http_code" -ne 200 ]]; then
        rm -f "$tmpfile"
        verbose "HTTP error: $http_code"
        echo "HTTP_ERROR:${http_code}"
        return 0
    fi

    parse_tracker_response "$tmpfile"
    rm -f "$tmpfile"
}

parse_tracker_response() {
    local response_file="$1"
    local content

    content=$(LC_ALL=C cat "$response_file" 2>/dev/null) || {
        echo "NETWORK_ERROR"
        return 0
    }

    # Check for failure reason
    if [[ "$content" =~ 14:failure\ reason([0-9]+): ]]; then
        local reason_len="${BASH_REMATCH[1]}"
        local after="${content#*14:failure reason"${reason_len}":}"
        local reason="${after:0:$reason_len}"
        verbose "Tracker failure: $reason"
        echo "TRACKER_ERROR:${reason}"
        return 0
    fi

    # Extract interval
    if [[ "$content" =~ 8:intervali([0-9]+)e ]]; then
        ANNOUNCE_INTERVAL="${BASH_REMATCH[1]}"
        verbose "Tracker interval: ${ANNOUNCE_INTERVAL}s"
    fi

    echo "OK"
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
    echo "${BOLD}  ANNOUNCE PARAMETERS${RESET}"
    echo "  ${DIM}Speed:${RESET}            ${UPLOAD_SPEED} KB/s"
    echo "  ${DIM}Mode:${RESET}             Announce (Ctrl+C to stop)"

    echo ""
}

################################################################################
# STATUS DISPLAY
################################################################################

show_status() {
    local uploaded=$1
    local torrent_size=$2
    local speed=$3
    local elapsed=$4
    local next_in=$5

    local ratio_str
    ratio_str=$(awk -v up="$uploaded" -v down="$torrent_size" 'BEGIN {
        if (down > 0) printf "%.2f", up / down
        else printf "0.00"
    }')

    local elapsed_str
    elapsed_str=$(format_duration "$elapsed")

    local next_str
    next_str=$(format_duration "$next_in")

    printf '\r\033[K  %s uploaded | ratio %s | %s KB/s | %s elapsed | next announce in %s ' \
        "$(format_size "$uploaded")" "$ratio_str" \
        "$speed" "$elapsed_str" "$next_str"
}

################################################################################
# ANNOUNCE LOOP
################################################################################

show_final_results() {
    # Restore cursor
    [[ -t 1 ]] && printf '\033[?25h'
    echo ""
    echo ""

    # Calculate ratio
    local download_size
    if [[ "$TORRENT_SIZE" != "0" ]]; then
        download_size=$TORRENT_SIZE
    else
        download_size=$((1024 * 1024 * 1024))  # 1 GB default
    fi

    local ratio
    ratio=$(awk -v up="$UPLOADED" -v down="$download_size" 'BEGIN { printf "%.2f", up / down }')

    local elapsed=$((SECONDS - SIMULATION_START))

    echo "  ${BOLD}${YELLOW}ANNOUNCE STOPPED${RESET} (Ctrl+C)"
    echo ""
    echo "  ${BOLD}RESULTS${RESET}"
    echo "  ${DIM}Uploaded:${RESET}      $(format_size "$UPLOADED")"
    echo "  ${DIM}Duration:${RESET}      $(format_duration "$elapsed")"

    if [[ "$TORRENT_SIZE" != "0" ]]; then
        echo "  ${DIM}Torrent size:${RESET}  $(format_size "$download_size")"
    fi

    echo "  ${DIM}Reported ratio:${RESET} ${BOLD}${ratio}${RESET}"

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

send_stopped_and_exit() {
    verbose "Sending stopped announce..."
    local result
    result=$(send_announce "stopped") || true
    verbose "Stopped announce result: ${result:-empty}"
    show_final_results
    exit 0
}

run_announce_loop() {
    compute_info_hash "$TORRENT_FILE"
    generate_peer_id

    # Set downloaded = torrent size (pretend we have the full file)
    if [[ "$TORRENT_SIZE" != "0" ]]; then
        DOWNLOADED=$TORRENT_SIZE
    else
        DOWNLOADED=$((1024 * 1024 * 1024))
    fi

    local torrent_size
    if [[ "$TORRENT_SIZE" != "0" ]]; then
        torrent_size=$TORRENT_SIZE
    else
        torrent_size=$((1024 * 1024 * 1024))
    fi

    echo "  ${BOLD}${BLUE}STARTING ANNOUNCES${RESET}"
    echo "  ${DIM}(Ctrl+C to stop)${RESET}"
    echo ""

    # Send initial "started" announce
    verbose "Sending started announce..."
    local result
    result=$(send_announce "started")
    case "$result" in
        OK)
            echo "  ${GREEN}Tracker responded OK (interval: ${ANNOUNCE_INTERVAL}s)${RESET}"
            ;;
        TRACKER_ERROR:*)
            echo "  ${RED}Tracker error: ${result#TRACKER_ERROR:}${RESET}"
            ;;
        HTTP_ERROR:*)
            echo "  ${YELLOW}HTTP error: ${result#HTTP_ERROR:}${RESET}"
            ;;
        NETWORK_ERROR)
            echo "  ${YELLOW}Network error (will retry)${RESET}"
            ;;
    esac
    echo ""

    local speed_bytes=$((UPLOAD_SPEED * 1024))

    # Detect fractional sleep support
    local sleep_interval=1
    if sleep 0.1 2>/dev/null; then
        sleep_interval=0.1
    fi

    local updates_per_sec
    if [[ "$sleep_interval" == "0.1" ]]; then
        updates_per_sec=10
    else
        updates_per_sec=1
    fi

    local chunk_size=$((speed_bytes / updates_per_sec))
    [[ $chunk_size -lt 1 ]] && chunk_size=1

    # Set up SIGINT trap
    trap 'send_stopped_and_exit' INT

    # Hide cursor during loop (terminal only)
    [[ -t 1 ]] && printf '\033[?25l'

    UPLOADED=0
    SIMULATION_START=$SECONDS
    LAST_ANNOUNCE_TIME=$SECONDS

    while true; do
        UPLOADED=$((UPLOADED + chunk_size))
        local elapsed=$((SECONDS - SIMULATION_START))
        local since_last=$((SECONDS - LAST_ANNOUNCE_TIME))
        local next_in=$((ANNOUNCE_INTERVAL - since_last))
        [[ $next_in -lt 0 ]] && next_in=0

        show_status "$UPLOADED" "$torrent_size" "$UPLOAD_SPEED" "$elapsed" "$next_in"

        # Time for a regular announce?
        if [[ $since_last -ge $ANNOUNCE_INTERVAL ]]; then
            verbose "Sending regular announce (uploaded: $UPLOADED)"
            result=$(send_announce "")
            LAST_ANNOUNCE_TIME=$SECONDS
            verbose "Announce result: $result"
        fi

        sleep "$sleep_interval"
    done
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
}

################################################################################
# ENTRY POINT
################################################################################

main() {
    setup_colors
    parse_arguments "$@"
    check_dependencies
    parse_torrent "$TORRENT_FILE"
    display_torrent_info

    if [[ "$DRY_RUN" == true ]]; then
        compute_info_hash "$TORRENT_FILE"
        echo "  ${DIM}info_hash:${RESET}  $INFO_HASH_HEX"
        echo ""
        echo "  ${DIM}DRY-RUN MODE -- No announce sent${RESET}"
        exit 0
    fi

    run_announce_loop
}

main "$@"
