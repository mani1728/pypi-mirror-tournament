#!/usr/bin/env bash

set -uo pipefail

PROJECT_ROOT="/workspace/projects/pypi-mirror-tournament"
MIRRORS_FILE="$PROJECT_ROOT/config/mirrors.conf"
CONFIG_FILE="$PROJECT_ROOT/config/tournament.conf"
STATE_FILE="$PROJECT_ROOT/state/current-winner"

usage() {
    echo "Usage: $0 --dry-run | --apply | --emergency"
}

if [[ $# -ne 1 ]]; then
    usage
    exit 64
fi

case "$1" in
    --dry-run)
        MODE="DRY_RUN"
        ;;
    --apply)
        MODE="APPLY"
        ;;
    --emergency)
        MODE="EMERGENCY"
        ;;
    *)
        usage
        exit 64
        ;;
esac

[[ -r "$CONFIG_FILE" ]] || {
    echo "ERROR: Cannot read $CONFIG_FILE" >&2
    exit 1
}

[[ -r "$MIRRORS_FILE" ]] || {
    echo "ERROR: Cannot read $MIRRORS_FILE" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$CONFIG_FILE"

mkdir -p "$LOG_DIR" "$STATE_DIR"

LOCK_FILE="$STATE_DIR/tournament.lock"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    echo "ERROR: Another PyPI Mirror Tournament is already running." >&2
    echo "LOCK_FILE: $LOCK_FILE" >&2
    exit 75
fi

TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG_FILE="$LOG_DIR/tournament_${TIMESTAMP}.log"
WORK_DIR="$(mktemp -d "/tmp/pypi-mirror-tournament.XXXXXX")"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

median3() {
    printf '%s\n' "$1" "$2" "$3" |
        sort -n |
        sed -n '2p'
}

CURRENT_NAME=""
CURRENT_URL=""

if [[ -r "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    CURRENT_NAME="${NAME:-}"
    CURRENT_URL="${URL:-}"
fi

log "================================================================="
log "                 PyPI MIRROR TOURNAMENT"
log "================================================================="
log "Started:        $(date --iso-8601=seconds)"
log "Host:           $(hostname)"
log "User:           $(id -un)"
log "Package:        $BENCHMARK_PACKAGE"
log "Download runs:  $DOWNLOAD_RUNS"
log "Mode:           $MODE"
log "Proxy:          FORCED DIRECT"
log "Current winner: ${CURRENT_NAME:-NONE}"
log "================================================================="

declare -a QUALIFIED_NAMES=()
declare -a QUALIFIED_URLS=()
declare -a QUALIFIED_MEDIANS=()

while IFS='|' read -r MIRROR_NAME MIRROR_URL; do

    [[ -z "${MIRROR_NAME// }" ]] && continue
    [[ "$MIRROR_NAME" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${MIRROR_URL:-}" ]] && continue

    MIRROR_URL="${MIRROR_URL%/}"

    log
    log "#################################################################"
    log "MIRROR: $MIRROR_NAME"
    log "URL:    $MIRROR_URL"
    log "#################################################################"

    PACKAGE_URL="$MIRROR_URL/$BENCHMARK_PACKAGE/"

    HEALTH_OUTPUT="$(
        curl \
            --noproxy '*' \
            --location \
            --silent \
            --show-error \
            --output /dev/null \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$HEALTH_TIMEOUT" \
            --write-out '%{http_code}|%{time_starttransfer}|%{time_total}|%{remote_ip}' \
            "$PACKAGE_URL" 2>&1
    )"
    HEALTH_RC=$?

    if [[ $HEALTH_RC -ne 0 ]]; then
        log "HEALTH:          FAILED"
        log "CURL_EXIT:       $HEALTH_RC"
        log "DETAIL:          $HEALTH_OUTPUT"
        log "QUALIFIED:       NO"
        continue
    fi

    IFS='|' read -r HTTP_CODE TTFB TOTAL REMOTE_IP <<< "$HEALTH_OUTPUT"

    log "HEALTH_HTTP:     $HTTP_CODE"
    log "REMOTE_IP:       $REMOTE_IP"
    log "TTFB_SECONDS:    $TTFB"
    log "HEALTH_TOTAL:    $TOTAL"

    if [[ "$HTTP_CODE" != "200" ]]; then
        log "HEALTH:          FAILED"
        log "REASON:          HTTP status is not 200"
        log "QUALIFIED:       NO"
        continue
    fi

    if awk -v ttfb="$TTFB" -v limit="$MAX_TTFB" \
        'BEGIN { exit !(ttfb > limit) }'
    then
        log "HEALTH:          FAILED"
        log "REASON:          TTFB exceeds ${MAX_TTFB}s limit"
        log "QUALIFIED:       NO"
        continue
    fi

    log "HEALTH:          PASSED"

    declare -a SPEEDS=()
    SUCCESSFUL_RUNS=0

    for ((RUN=1; RUN<=DOWNLOAD_RUNS; RUN++)); do

        DEST="$WORK_DIR/${MIRROR_NAME}_${RUN}"
        mkdir -p "$DEST"

        log
        log "--- DOWNLOAD RUN $RUN/$DOWNLOAD_RUNS ---"

        START_NS="$(date +%s%N)"

        timeout --signal=TERM --kill-after=5s "${DOWNLOAD_TIMEOUT}s" \
            env \
                -u HTTP_PROXY \
                -u HTTPS_PROXY \
                -u ALL_PROXY \
                -u http_proxy \
                -u https_proxy \
                -u all_proxy \
                NO_PROXY='*' \
                no_proxy='*' \
                python3 -m pip download \
                    --disable-pip-version-check \
                    --no-cache-dir \
                    --no-deps \
                    --index-url "$MIRROR_URL" \
                    --dest "$DEST" \
                    "$BENCHMARK_PACKAGE" \
                    >>"$LOG_FILE" 2>&1

        PIP_RC=$?

        END_NS="$(date +%s%N)"
        ELAPSED_NS=$((END_NS - START_NS))

        FILE="$(find "$DEST" -maxdepth 1 -type f -print -quit)"

        if [[ $PIP_RC -eq 0 && -n "$FILE" && -f "$FILE" ]]; then

            BYTES="$(stat -c '%s' "$FILE")"

            ELAPSED="$(
                awk -v ns="$ELAPSED_NS" \
                    'BEGIN { printf "%.3f", ns / 1000000000 }'
            )"

            SPEED="$(
                awk -v b="$BYTES" -v ns="$ELAPSED_NS" \
                    'BEGIN {
                        s = ns / 1000000000;
                        if (s > 0)
                            printf "%.4f", (b / 1048576) / s;
                        else
                            printf "0";
                    }'
            )"

            SPEEDS+=("$SPEED")
            ((SUCCESSFUL_RUNS+=1))

            log "RESULT:          SUCCESS"
            log "FILE:            $(basename "$FILE")"
            log "SIZE_BYTES:      $BYTES"
            log "TOTAL_SECONDS:   $ELAPSED"
            log "SPEED_MBPS:      $SPEED"

        else

            log "RESULT:          FAILED"
            log "PIP_EXIT:        $PIP_RC"

            if [[ $PIP_RC -eq 124 || $PIP_RC -eq 137 ]]; then
                log "REASON:          DOWNLOAD_TIMEOUT"
            fi

        fi

        rm -rf "$DEST"

    done

    log
    log "SUCCESSFUL_RUNS: $SUCCESSFUL_RUNS/$DOWNLOAD_RUNS"

    if [[ "$REQUIRE_ALL_RUNS" == "true" &&
          "$SUCCESSFUL_RUNS" -ne "$DOWNLOAD_RUNS" ]]; then
        log "QUALIFIED:       NO"
        continue
    fi

    if [[ "$DOWNLOAD_RUNS" -ne 3 ]]; then
        log "ERROR: Current engine requires DOWNLOAD_RUNS=3."
        log "QUALIFIED:       NO"
        continue
    fi

    MEDIAN="$(median3 "${SPEEDS[0]}" "${SPEEDS[1]}" "${SPEEDS[2]}")"

    log "MEDIAN_MBPS:     $MEDIAN"
    log "QUALIFIED:       YES"

    QUALIFIED_NAMES+=("$MIRROR_NAME")
    QUALIFIED_URLS+=("$MIRROR_URL")
    QUALIFIED_MEDIANS+=("$MEDIAN")

done < "$MIRRORS_FILE"

log
log "================================================================="
log "                         RESULTS"
log "================================================================="

if [[ ${#QUALIFIED_NAMES[@]} -eq 0 ]]; then
    log "ERROR: No mirror qualified."
    log "No pip configuration was changed."
    exit 2
fi

BEST_INDEX=0
CURRENT_INDEX=-1

for ((i=0; i<${#QUALIFIED_NAMES[@]}; i++)); do

    log "$(printf '%-16s Median: %s MB/s' \
        "${QUALIFIED_NAMES[$i]}" \
        "${QUALIFIED_MEDIANS[$i]}")"

    if [[ -n "$CURRENT_URL" &&
          "${QUALIFIED_URLS[$i]}" == "${CURRENT_URL%/}" ]]; then
        CURRENT_INDEX=$i
    fi

    if awk \
        -v candidate="${QUALIFIED_MEDIANS[$i]}" \
        -v current="${QUALIFIED_MEDIANS[$BEST_INDEX]}" \
        'BEGIN { exit !(candidate > current) }'
    then
        BEST_INDEX=$i
    fi

done

BEST_NAME="${QUALIFIED_NAMES[$BEST_INDEX]}"
BEST_URL="${QUALIFIED_URLS[$BEST_INDEX]}"
BEST_MEDIAN="${QUALIFIED_MEDIANS[$BEST_INDEX]}"

log
log "BEST_MIRROR:     $BEST_NAME"
log "BEST_URL:        $BEST_URL"
log "BEST_MEDIAN:     $BEST_MEDIAN MB/s"

SELECTED_NAME="$BEST_NAME"
SELECTED_URL="$BEST_URL"
SELECTED_MEDIAN="$BEST_MEDIAN"
SHOULD_SWITCH=false
REASON=""

case "$MODE" in

    DRY_RUN)
        REASON="Dry run only"
        ;;

    EMERGENCY)
        SHOULD_SWITCH=true
        REASON="Emergency replacement of unhealthy current winner"
        ;;

    APPLY)

        if [[ $CURRENT_INDEX -lt 0 ]]; then
            SHOULD_SWITCH=true
            REASON="Current winner did not qualify"
        else
            CURRENT_MEDIAN="${QUALIFIED_MEDIANS[$CURRENT_INDEX]}"

            log "CURRENT_MEDIAN:  $CURRENT_MEDIAN MB/s"

            if [[ "$BEST_URL" == "${CURRENT_URL%/}" ]]; then
                SHOULD_SWITCH=false
                REASON="Current winner remains fastest"
            else
                REQUIRED_SPEED="$(
                    awk \
                        -v current="$CURRENT_MEDIAN" \
                        -v threshold="$SWITCH_THRESHOLD_PERCENT" \
                        'BEGIN {
                            printf "%.4f",
                                current * (1 + threshold / 100)
                        }'
                )"

                log "SWITCH_LIMIT:    $REQUIRED_SPEED MB/s"
                log "THRESHOLD:       ${SWITCH_THRESHOLD_PERCENT}%"

                if awk \
                    -v best="$BEST_MEDIAN" \
                    -v required="$REQUIRED_SPEED" \
                    'BEGIN { exit !(best >= required) }'
                then
                    SHOULD_SWITCH=true
                    REASON="Challenger exceeded switch threshold"
                else
                    SHOULD_SWITCH=false
                    REASON="Improvement below switch threshold"
                fi
            fi
        fi
        ;;
esac

if [[ "$MODE" == "DRY_RUN" ]]; then
    log
    log "ACTION:          NO CHANGE"
    log "REASON:          $REASON"
    log "DRY RUN: pip configuration was NOT changed."
    log "Finished:        $(date --iso-8601=seconds)"
    log "================================================================="
    exit 0
fi

if [[ "$SHOULD_SWITCH" != "true" ]]; then
    log
    log "ACTION:          KEEP CURRENT WINNER"
    log "REASON:          $REASON"
    log "Finished:        $(date --iso-8601=seconds)"
    log "================================================================="
    exit 0
fi

log
log "ACTION:          SWITCH"
log "NEW_WINNER:      $SELECTED_NAME"
log "REASON:          $REASON"

python3 -m pip config --user set global.index-url "$SELECTED_URL" \
    >>"$LOG_FILE" 2>&1

CONFIG_RC=$?

if [[ $CONFIG_RC -ne 0 ]]; then
    log "ERROR: Failed to update pip configuration."
    log "State file was NOT changed."
    exit 3
fi

VERIFY_URL="$(
    python3 -m pip config --user get global.index-url 2>/dev/null || true
)"

if [[ "${VERIFY_URL%/}" != "${SELECTED_URL%/}" ]]; then
    log "ERROR: pip configuration verification failed."
    log "EXPECTED: $SELECTED_URL"
    log "ACTUAL:   $VERIFY_URL"
    log "State file was NOT changed."
    exit 4
fi

TEMP_STATE="$STATE_DIR/current-winner.tmp.$$"

{
    printf 'NAME=%q\n' "$SELECTED_NAME"
    printf 'URL=%q\n' "$SELECTED_URL"
    printf 'SELECTED_AT=%q\n' "$(date --iso-8601=seconds)"
    printf 'SELECTION_REASON=%q\n' "$REASON"
} > "$TEMP_STATE"

chmod 644 "$TEMP_STATE"
mv "$TEMP_STATE" "$STATE_FILE"

log "PIP_CONFIG:      VERIFIED"
log "STATE:           UPDATED"
log "ACTIVE_WINNER:   $SELECTED_NAME"
log "Finished:        $(date --iso-8601=seconds)"
log "================================================================="

exit 0
