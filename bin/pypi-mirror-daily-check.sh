#!/usr/bin/env bash

set -uo pipefail

PROJECT_ROOT="/workspace/projects/pypi-mirror-tournament"
CONFIG_FILE="$PROJECT_ROOT/config/tournament.conf"
STATE_FILE="$PROJECT_ROOT/state/current-winner"

if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "ERROR: Cannot read $CONFIG_FILE" >&2
    exit 1
fi

if [[ ! -r "$STATE_FILE" ]]; then
    echo "ERROR: Cannot read $STATE_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# shellcheck disable=SC1090
source "$STATE_FILE"

TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG_FILE="$LOG_DIR/daily_${TIMESTAMP}.log"

log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

run_emergency_tournament() {
    local tournament_script="$PROJECT_ROOT/bin/pypi-mirror-tournament.sh"
    local emergency_rc

    log
    log "EMERGENCY:     START"
    log "ACTION:        RUN_EMERGENCY_TOURNAMENT"

    if [[ ! -x "$tournament_script" ]]; then
        log "EMERGENCY:     FAILED"
        log "REASON:        Tournament script is not executable"
        log "SCRIPT:        $tournament_script"
        return 10
    fi

    "$tournament_script" --emergency
    emergency_rc=$?

    if [[ $emergency_rc -eq 0 ]]; then
        log "EMERGENCY:     RECOVERED"
        log "RECOVERY_EXIT: 0"
        return 0
    fi

    log "EMERGENCY:     FAILED"
    log "RECOVERY_EXIT: $emergency_rc"
    return "$emergency_rc"
}

fail_and_recover() {
    local recovery_rc

    log "STATUS:        FAILED"
    log "ACTION:        EMERGENCY_TOURNAMENT_REQUIRED"

    run_emergency_tournament
    recovery_rc=$?

    if [[ $recovery_rc -eq 0 ]]; then
        log "STATUS:        RECOVERED"
        log "ACTION:        EMERGENCY_TOURNAMENT_SUCCEEDED"
        log "Finished:      $(date --iso-8601=seconds)"
        log "================================================================="
        exit 0
    fi

    log "STATUS:        RECOVERY_FAILED"
    log "ACTION:        MANUAL_ATTENTION_REQUIRED"
    log "RECOVERY_EXIT: $recovery_rc"
    log "Finished:      $(date --iso-8601=seconds)"
    log "================================================================="
    exit "$recovery_rc"
}

PACKAGE_URL="${URL%/}/${DAILY_TEST_PACKAGE}/"

log "================================================================="
log "              PyPI MIRROR DAILY QUICK CHECK"
log "================================================================="
log "Started:       $(date --iso-8601=seconds)"
log "Mirror:        $NAME"
log "URL:           $URL"
log "Package:       $DAILY_TEST_PACKAGE"
log "Proxy:         FORCED DIRECT"
log "================================================================="

RESULT="$(
    curl \
        --noproxy '*' \
        --location \
        --silent \
        --show-error \
        --output /dev/null \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$HEALTH_TIMEOUT" \
        --write-out '%{http_code}|%{time_connect}|%{time_starttransfer}|%{time_total}|%{remote_ip}' \
        "$PACKAGE_URL" 2>&1
)"
CURL_RC=$?

if [[ $CURL_RC -ne 0 ]]; then
    log "CURL_EXIT:     $CURL_RC"
    log "DETAIL:        $RESULT"
    fail_and_recover
fi

IFS='|' read -r HTTP_CODE CONNECT_TIME TTFB TOTAL_TIME REMOTE_IP <<< "$RESULT"

log "HTTP:          $HTTP_CODE"
log "REMOTE_IP:     $REMOTE_IP"
log "CONNECT:       ${CONNECT_TIME}s"
log "TTFB:          ${TTFB}s"
log "TOTAL:         ${TOTAL_TIME}s"

if [[ "$HTTP_CODE" != "200" ]]; then
    log "REASON:        HTTP status is not 200"
    fail_and_recover
fi

if awk -v ttfb="$TTFB" -v limit="$MAX_TTFB" \
    'BEGIN { exit !(ttfb > limit) }'
then
    log "REASON:        TTFB exceeds ${MAX_TTFB}s"
    fail_and_recover
fi

log
log "REAL_DOWNLOAD: START"

DOWNLOAD_DIR="$(mktemp -d "/tmp/pypi-mirror-daily.XXXXXX")"

cleanup() {
    rm -rf "$DOWNLOAD_DIR"
}
trap cleanup EXIT

timeout --signal=TERM --kill-after=5s "${DAILY_DOWNLOAD_TIMEOUT}s" \
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
            --index-url "${URL%/}" \
            --dest "$DOWNLOAD_DIR" \
            "$DAILY_TEST_PACKAGE" \
            >>"$LOG_FILE" 2>&1

PIP_RC=$?

DOWNLOADED_FILE="$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -print -quit)"

if [[ $PIP_RC -ne 0 || -z "$DOWNLOADED_FILE" || ! -f "$DOWNLOADED_FILE" ]]; then
    log "REAL_DOWNLOAD: FAILED"
    log "PIP_EXIT:      $PIP_RC"

    if [[ $PIP_RC -eq 124 || $PIP_RC -eq 137 ]]; then
        log "REASON:        DOWNLOAD_TIMEOUT"
    else
        log "REASON:        Real pip download failed"
    fi

    fail_and_recover
fi

DOWNLOAD_BYTES="$(stat -c '%s' "$DOWNLOADED_FILE")"

log "REAL_DOWNLOAD: PASSED"
log "DOWNLOADED:    $(basename "$DOWNLOADED_FILE")"
log "SIZE_BYTES:    $DOWNLOAD_BYTES"
log "STATUS:        HEALTHY"
log "ACTION:        KEEP_CURRENT_WINNER"
log "Finished:      $(date --iso-8601=seconds)"
log "================================================================="

exit 0
