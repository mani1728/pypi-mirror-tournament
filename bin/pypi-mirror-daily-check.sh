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

PACKAGE_URL="${URL%/}/${BENCHMARK_PACKAGE}/"

log "================================================================="
log "              PyPI MIRROR DAILY QUICK CHECK"
log "================================================================="
log "Started:       $(date --iso-8601=seconds)"
log "Mirror:        $NAME"
log "URL:           $URL"
log "Package:       $BENCHMARK_PACKAGE"
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
    log "STATUS:        FAILED"
    log "CURL_EXIT:     $CURL_RC"
    log "DETAIL:        $RESULT"
    log "ACTION:        EMERGENCY_TOURNAMENT_REQUIRED"
    exit 2
fi

IFS='|' read -r HTTP_CODE CONNECT_TIME TTFB TOTAL_TIME REMOTE_IP <<< "$RESULT"

log "HTTP:          $HTTP_CODE"
log "REMOTE_IP:     $REMOTE_IP"
log "CONNECT:       ${CONNECT_TIME}s"
log "TTFB:          ${TTFB}s"
log "TOTAL:         ${TOTAL_TIME}s"

if [[ "$HTTP_CODE" != "200" ]]; then
    log "STATUS:        FAILED"
    log "REASON:        HTTP status is not 200"
    log "ACTION:        EMERGENCY_TOURNAMENT_REQUIRED"
    exit 2
fi

if awk -v ttfb="$TTFB" -v limit="$MAX_TTFB" \
    'BEGIN { exit !(ttfb > limit) }'
then
    log "STATUS:        FAILED"
    log "REASON:        TTFB exceeds ${MAX_TTFB}s"
    log "ACTION:        EMERGENCY_TOURNAMENT_REQUIRED"
    exit 2
fi

log "STATUS:        HEALTHY"
log "ACTION:        KEEP_CURRENT_WINNER"
log "Finished:      $(date --iso-8601=seconds)"
log "================================================================="

exit 0
