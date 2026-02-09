#!/usr/bin/env bash

################################################################################
# ratio-master - Simulateur d'upload torrent pedagogique
#
# Usage: ratio-master.sh [OPTIONS] <fichier.torrent>
#
# Simule localement une progression d'upload pour comprendre le ratio
# sur les trackers BitTorrent. Aucune connexion reseau reelle.
#
# Licence: MIT
################################################################################

set -euo pipefail

readonly VERSION="1.0.1"

################################################################################
# CONFIGURATION PAR DEFAUT
################################################################################

readonly DEFAULT_UPLOAD_SIZE=$((5 * 1024 * 1024))  # 5 Mo en octets
readonly DEFAULT_SPEED=512                          # 512 KB/s
readonly PROGRESS_BAR_WIDTH=40

################################################################################
# VARIABLES GLOBALES
################################################################################

TORRENT_FILE=""
UPLOAD_SIZE=$DEFAULT_UPLOAD_SIZE
UPLOAD_SPEED=$DEFAULT_SPEED
SIMULATION_TIME=0
DRY_RUN=false
VERBOSE=false

# Respecter le standard NO_COLOR (https://no-color.org/)
# Capturer l'env var AVANT de la remplacer par notre variable interne
_NO_COLOR_ENV="${NO_COLOR+set}"
NO_COLOR=false

# Variables couleur (initialisees vides pour set -u)
BOLD="" DIM="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" CYAN=""

# Informations torrent (remplies par parse_torrent)
TORRENT_NAME=""
TORRENT_SIZE=""
TORRENT_PIECES=""
TORRENT_PIECE_LENGTH=""
TORRENT_TRACKER=""
TORRENT_COMMENT=""

################################################################################
# COULEURS
################################################################################

setup_colors() {
    # Si couleurs desactivees, tout reste vide (deja initialise)
    if [[ "$NO_COLOR" == true ]] || [[ ! -t 1 ]] || [[ -n "${_NO_COLOR_ENV:-}" ]]; then
        return
    fi

    # Activer les couleurs
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
# GESTION DES SIGNAUX
################################################################################

cleanup() {
    # Restaurer le curseur si terminal interactif
    if [[ -t 1 ]]; then
        printf '\033[?25h' 2>/dev/null || :
    fi
}

trap cleanup EXIT INT TERM HUP

################################################################################
# UTILITAIRES
################################################################################

error() {
    setup_colors
    echo "${RED}ERREUR:${RESET} $*" >&2
    exit 1
}

verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo "${DIM}[DEBUG] $*${RESET}" >&2
    fi
}

# Conversion d'unites avec precision decimale
format_size() {
    local bytes=$1

    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes} o"
        return
    fi

    awk -v b="$bytes" 'BEGIN {
        split("Ko Mo Go To", units, " ")
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

# Conversion secondes -> format lisible
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
# AIDE ET VERSION
################################################################################

show_version() {
    echo "ratio-master ${VERSION}"
}

show_help() {
    cat << 'EOF'
SYNOPSIS
    ratio-master.sh [OPTIONS] <fichier.torrent>

DESCRIPTION
    Simule localement une progression d'upload torrent pour comprendre
    le fonctionnement du ratio sur les trackers BitTorrent.

    Ce script n'effectue AUCUNE connexion reseau reelle et ne communique
    avec aucun tracker. C'est une simulation pedagogique uniquement.

ARGUMENTS
    <fichier.torrent>
        Fichier torrent a analyser (obligatoire)

OPTIONS
    -s, --speed <KB/s>
        Vitesse d'upload simulee en kilo-octets par seconde
        Par defaut: 512 KB/s

    -S, --size <Mo>
        Taille d'upload a simuler en mega-octets
        Par defaut: 5 Mo

    -t, --time <secondes>
        Duree de la simulation en secondes
        La vitesse est calculee automatiquement

    --dry-run
        Affiche les informations sans lancer la simulation

    --no-color
        Desactive les couleurs dans la sortie

    -v, --verbose
        Mode verbose pour le debogage

    -V, --version
        Affiche la version

    -h, --help
        Affiche cette aide

EXEMPLES
    # Simulation avec parametres par defaut (512 KB/s, 5 Mo)
    ratio-master.sh mon-fichier.torrent

    # Simulation avec vitesse personnalisee (1 MB/s)
    ratio-master.sh --speed 1024 mon-fichier.torrent

    # Simulation de 50 Mo d'upload
    ratio-master.sh --size 50 mon-fichier.torrent

    # Simulation sur 30 secondes
    ratio-master.sh --time 30 mon-fichier.torrent

    # Affichage des infos seulement
    ratio-master.sh --dry-run mon-fichier.torrent

CALCUL DU RATIO
    Ratio = Uploade / Telecharge
    - Ratio < 1.0  : Tu dois encore uploader
    - Ratio = 1.0  : Tu as donne autant que recu
    - Ratio > 1.0  : Tu es un bon membre de la communaute !

NOTE
    Ce script est purement pedagogique. Pour ameliorer votre ratio
    reel sur un tracker, laissez vos torrents en seed apres le
    telechargement.

EOF
}

################################################################################
# PARSING BENCODE (FORMAT TORRENT)
################################################################################

# Parsing bencode avec outils POSIX uniquement (100% bash)
parse_torrent_bash() {
    local torrent_file="$1"
    local content name="" size="" piece_length="" tracker="" comment=""

    # Lire le contenu brut en tant que texte binaire
    content=$(LC_ALL=C cat "$torrent_file" 2>/dev/null)

    # Nom du torrent - chercher "4:name" suivi d'une longueur et du nom
    if [[ "$content" =~ 4:name([0-9]+): ]]; then
        local name_len="${BASH_REMATCH[1]}"
        local after_match="${content#*4:name"${name_len}":}"
        name="${after_match:0:$name_len}"
    else
        # Fallback: utiliser le nom du fichier
        name="${torrent_file##*/}"
        name="${name%.torrent}"
    fi

    # Taille totale - deux cas :
    # 1. Fichier simple : "6:lengthi<N>e" dans le dict info
    # 2. Multi-fichiers : "5:filesl" avec plusieurs "6:lengthi<N>e"
    if [[ "$content" =~ 5:filesl ]]; then
        # Multi-fichiers : extraire la section "files" et additionner
        local files_section="${content#*5:filesl}"

        # Arreter a la fermeture de la liste files
        if [[ "$files_section" =~ (.*[ee])4:name ]]; then
            files_section="${BASH_REMATCH[1]}"
        fi

        # Extraire tous les "lengthi<nombre>e"
        local total=0
        while [[ "$files_section" =~ lengthi([0-9]+)e ]]; do
            total=$((total + BASH_REMATCH[1]))
            files_section="${files_section#*lengthi"${BASH_REMATCH[1]}"e}"
        done

        if [[ $total -gt 0 ]]; then
            size="$total"
        fi
    else
        # Fichier simple
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

    # Commentaire
    if [[ "$content" =~ comment([0-9]+): ]]; then
        local comment_len="${BASH_REMATCH[1]}"
        local after_comment="${content#*comment"${comment_len}":}"
        comment="${after_comment:0:$comment_len}"
    fi

    # Output en une seule fois (plus rapide)
    printf 'NAME=%s\nSIZE=%s\nPIECE_LENGTH=%s\nTRACKER=%s\nCOMMENT=%s\n' \
        "$name" \
        "${size:-0}" \
        "${piece_length:-262144}" \
        "$tracker" \
        "$comment"
}

# Parse le fichier torrent
parse_torrent() {
    local torrent_file="$1"

    verbose "Parsing du fichier torrent: $torrent_file"

    if [[ ! -f "$torrent_file" ]]; then
        error "Le fichier torrent n'existe pas: $torrent_file"
    fi

    if [[ ! -r "$torrent_file" ]]; then
        error "Le fichier torrent n'est pas lisible: $torrent_file"
    fi

    # Verifier la signature bencode (doit commencer par 'd')
    local first_byte
    first_byte=$(LC_ALL=C head -c1 "$torrent_file")
    if [[ "$first_byte" != "d" ]]; then
        error "Le fichier ne semble pas etre un fichier torrent valide"
    fi

    # Parser avec bash pur uniquement
    verbose "Parsing bencode avec bash pur"
    local parsed
    parsed=$(parse_torrent_bash "$torrent_file")

    # Extraire les valeurs via parameter expansion (0 sous-shell)
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

    # Valeurs par defaut si vides
    if [[ -z "$TORRENT_NAME" ]]; then
        TORRENT_NAME="${torrent_file##*/}"
        TORRENT_NAME="${TORRENT_NAME%.torrent}"
    fi
    if [[ -z "$TORRENT_PIECE_LENGTH" ]]; then
        TORRENT_PIECE_LENGTH=262144
    fi

    # Calculer le nombre de pieces
    if [[ "$TORRENT_SIZE" =~ ^[0-9]+$ && "$TORRENT_SIZE" -gt 0 ]]; then
        TORRENT_PIECES=$(( (TORRENT_SIZE + TORRENT_PIECE_LENGTH - 1) / TORRENT_PIECE_LENGTH ))
    else
        TORRENT_SIZE="0"
        TORRENT_PIECES="?"
    fi

    verbose "Nom: $TORRENT_NAME"
    verbose "Taille: $TORRENT_SIZE octets"
    verbose "Pieces: $TORRENT_PIECES"
    verbose "Tracker: $TORRENT_TRACKER"
}

################################################################################
# AFFICHAGE DES INFORMATIONS
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
    echo "${BOLD}  FICHIER TORRENT${RESET}"
    echo "  ${DIM}Nom:${RESET}           ${TORRENT_NAME}"

    if [[ "$TORRENT_SIZE" != "0" ]]; then
        echo "  ${DIM}Taille:${RESET}        $(format_size "$TORRENT_SIZE")"
        echo "  ${DIM}Pieces:${RESET}        ${TORRENT_PIECES} ($(format_size "$TORRENT_PIECE_LENGTH")/piece)"
    else
        echo "  ${DIM}Taille:${RESET}        Inconnue"
    fi

    if [[ -n "$TORRENT_TRACKER" ]]; then
        echo "  ${DIM}Tracker:${RESET}       ${TORRENT_TRACKER}"
    fi

    if [[ -n "$TORRENT_COMMENT" ]]; then
        echo "  ${DIM}Commentaire:${RESET}   ${TORRENT_COMMENT}"
    fi

    echo ""
    echo "${BOLD}  PARAMETRES DE SIMULATION${RESET}"
    echo "  ${DIM}Upload simule:${RESET}   $(format_size "$UPLOAD_SIZE")"
    echo "  ${DIM}Vitesse:${RESET}         ${UPLOAD_SPEED} KB/s"

    # Calculer la duree estimee
    local speed_bytes=$((UPLOAD_SPEED * 1024))
    if [[ $speed_bytes -gt 0 ]]; then
        local estimated_seconds=$((UPLOAD_SIZE / speed_bytes))
        echo "  ${DIM}Duree estimee:${RESET}   $(format_duration "$estimated_seconds")"
    fi

    echo ""
}

################################################################################
# BARRE DE PROGRESSION
################################################################################

show_progress() {
    local current=$1
    local total=$2
    local speed=$3

    # Pourcentage
    local percent=0
    if [[ $total -gt 0 ]]; then
        percent=$((current * 100 / total))
    fi

    # Barre visuelle
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

    # Affichage sur une ligne (effacer la ligne pour eviter les artefacts)
    printf '\r\033[K  [%s] %3d%% | %s / %s | %s KB/s | %s ' \
        "$bar" "$percent" \
        "$(format_size "$current")" "$(format_size "$total")" \
        "$speed" "$eta_str"
}

################################################################################
# SIMULATION D'UPLOAD
################################################################################

simulate_upload() {
    echo "  ${BOLD}${BLUE}DEMARRAGE DE LA SIMULATION${RESET}"
    echo "  ${DIM}(Aucune donnee n'est reellement envoyee)${RESET}"
    echo ""

    local uploaded=0
    local speed_bytes=$((UPLOAD_SPEED * 1024))

    # Detecter le support de sleep fractionnaire
    local sleep_interval=0.1
    local updates_per_sec=10
    if ! sleep 0.1 2>/dev/null; then
        sleep_interval=1
        updates_per_sec=1
    fi

    local chunk_size=$((speed_bytes / updates_per_sec))
    # Chunk minimum de 1 octet pour eviter boucle infinie
    [[ $chunk_size -lt 1 ]] && chunk_size=1

    # Cacher le curseur pendant la simulation (terminal uniquement)
    [[ -t 1 ]] && printf '\033[?25l'

    while [[ $uploaded -lt $UPLOAD_SIZE ]]; do
        local remaining=$((UPLOAD_SIZE - uploaded))
        local current_chunk=$((chunk_size < remaining ? chunk_size : remaining))
        uploaded=$((uploaded + current_chunk))

        show_progress "$uploaded" "$UPLOAD_SIZE" "$UPLOAD_SPEED"

        sleep "$sleep_interval"
    done

    # Affichage final a 100%
    show_progress "$UPLOAD_SIZE" "$UPLOAD_SIZE" "$UPLOAD_SPEED"
    [[ -t 1 ]] && printf '\033[?25h'  # Restaurer le curseur
    echo ""
    echo ""

    # Calcul du ratio simule
    local download_size
    if [[ "$TORRENT_SIZE" != "0" ]]; then
        download_size=$TORRENT_SIZE
    else
        download_size=$((1024 * 1024 * 1024))  # 1 Go par defaut
    fi

    local ratio
    ratio=$(awk -v up="$UPLOAD_SIZE" -v down="$download_size" 'BEGIN { printf "%.2f", up / down }')

    echo "  ${BOLD}${GREEN}SIMULATION TERMINEE${RESET}"
    echo ""
    echo "  ${BOLD}RESULTATS${RESET}"
    echo "  ${DIM}Uploade:${RESET}       $(format_size "$UPLOAD_SIZE")"

    if [[ "$TORRENT_SIZE" != "0" ]]; then
        echo "  ${DIM}Taille torrent:${RESET} $(format_size "$download_size")"
    fi

    echo "  ${DIM}Ratio simule:${RESET}  ${BOLD}${ratio}${RESET}"

    local ratio_status
    ratio_status=$(awk -v r="$ratio" 'BEGIN { print (r < 1.0) ? "low" : (r > 1.0) ? "high" : "equal" }')

    case "$ratio_status" in
        low)
            echo "  ${DIM}Statut:${RESET}        ${YELLOW}Ratio inferieur a 1.0${RESET}"
            ;;
        equal)
            echo "  ${DIM}Statut:${RESET}        ${GREEN}Ratio egal a 1.0${RESET}"
            ;;
        high)
            echo "  ${DIM}Statut:${RESET}        ${GREEN}Ratio superieur a 1.0 - Excellent !${RESET}"
            ;;
    esac

    echo ""
    echo "  ${BOLD}CONSEIL${RESET}"
    echo "  Pour maintenir un bon ratio sur un tracker reel :"
    echo "  1. Laisse tes torrents en seed apres le telechargement"
    echo "  2. Priorise les nouveaux torrents (freeleech)"
    echo "  3. Utilise un seedbox si ta connexion est limitee"
    echo ""
}

################################################################################
# PARSING DES ARGUMENTS
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
                    error "L'option --speed requiert une valeur"
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    error "La vitesse doit etre un nombre entier positif"
                fi
                if [[ "$2" -eq 0 ]]; then
                    error "La vitesse ne peut pas etre 0"
                fi
                UPLOAD_SPEED="$2"
                shift 2
                ;;
            -S|--size)
                if [[ -z "${2:-}" ]]; then
                    error "L'option --size requiert une valeur (en Mo)"
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    error "La taille doit etre un nombre entier positif"
                fi
                if [[ "$2" -eq 0 ]]; then
                    error "La taille ne peut pas etre 0"
                fi
                if [[ "$2" -gt 8388608 ]]; then
                    error "La taille ne peut pas depasser 8388608 Mo (8 To)"
                fi
                UPLOAD_SIZE=$(($2 * 1024 * 1024))
                shift 2
                ;;
            -t|--time)
                if [[ -z "${2:-}" ]]; then
                    error "L'option --time requiert une valeur"
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    error "Le temps doit etre un nombre entier positif"
                fi
                if [[ "$2" -eq 0 ]]; then
                    error "Le temps ne peut pas etre 0"
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
                error "Option inconnue: $1 (utilise -h pour l'aide)"
                ;;
            *)
                if [[ -n "$TORRENT_FILE" ]]; then
                    error "Trop de fichiers specifies. Un seul fichier .torrent attendu."
                fi
                TORRENT_FILE="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$TORRENT_FILE" ]]; then
        error "Aucun fichier torrent specifie. Utilise -h pour l'aide."
    fi

    if [[ ! "$TORRENT_FILE" =~ \.torrent$ ]]; then
        error "Le fichier doit avoir l'extension .torrent"
    fi

    # Si --time est specifie, recalculer la vitesse
    if [[ $SIMULATION_TIME -gt 0 ]]; then
        UPLOAD_SPEED=$((UPLOAD_SIZE / SIMULATION_TIME / 1024))
        if [[ $UPLOAD_SPEED -lt 1 ]]; then
            UPLOAD_SPEED=1
        fi
    fi
}

################################################################################
# POINT D'ENTREE
################################################################################

main() {
    setup_colors
    parse_arguments "$@"
    parse_torrent "$TORRENT_FILE"
    display_torrent_info

    if [[ "$DRY_RUN" == true ]]; then
        echo "  ${DIM}MODE DRY-RUN - Aucune simulation effectuee${RESET}"
        exit 0
    fi

    simulate_upload
}

main "$@"
