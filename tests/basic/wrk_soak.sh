#!/bin/bash

# Scheduler profile: servers park for batched CQE reaping (override with
# FIBERUS_PROFILE=latency for A/B against the game-tuned idle behavior)
export FIBERUS_PROFILE=${FIBERUS_PROFILE:-server}
# wrk_soak.sh — Phase 4 soak gate.
#
# Runs the server under sustained load for ${SOAK_DURATION:-1800} seconds
# while sampling VmRSS every 10 seconds. wrk tolerates HTTP 500s (LoadTest
# does not), so this gives a real soak signal instead of aborting at the
# first non-2xx.
#
# Usage: invoke from within tecdoc-api/ (or any dir that has ./bin/Main).
# Env: SOAK_DURATION (seconds, default 1800),
#      SOAK_URL (default http://127.0.0.1:8080/),
#      SOAK_THREADS/SOAK_CONN (default 4/64).
#
# Gate criteria (exit 0 = pass):
#   1. server alive at t=SOAK_DURATION
#   2. no SIGSEGV / SIGABRT / [GC-BUG] / [D1-POST-MARK] UNMARKED in server log
#   3. HTTP non-2xx rate = 0 (any non-2xx means a container leaked a raw
#      cross-fiber pointer; Phase 1 audit counter should also be 0)
#   4. RSS at t=SOAK_DURATION <= 2 * RSS at t=180 (workload plateau)

set -u
DUR="${SOAK_DURATION:-1800}"
URL="${SOAK_URL:-http://127.0.0.1:8080/}"
THR="${SOAK_THREADS:-4}"
CON="${SOAK_CONN:-64}"

if [ ! -x ./bin/Main ]; then
    echo "error: ./bin/Main not found (run from tecdoc-api/ or equiv)" >&2
    exit 2
fi
if ! command -v wrk >/dev/null 2>&1; then
    echo "error: wrk not installed (apt install wrk)" >&2
    exit 2
fi

SRV_LOG="soak_server.log"
RSS_LOG="soak_rss.log"
WRK_LOG="soak_wrk.log"
: > "$SRV_LOG"
: > "$RSS_LOG"
: > "$WRK_LOG"

./bin/Main > "$SRV_LOG" 2>&1 &
PID=$!
trap "kill $PID 2>/dev/null; wait $PID 2>/dev/null" EXIT

# Wait for server readiness
for i in $(seq 1 30); do
    if curl -sS -m 1 "$URL" >/dev/null 2>&1; then break; fi
    sleep 1
done

# RSS sampler — one line per 10s: "<unix_time> <rss_kB>"
(
    while kill -0 $PID 2>/dev/null; do
        awk '/^VmRSS:/{print systime(), $2; exit}' /proc/$PID/status >> "$RSS_LOG" 2>/dev/null
        sleep 10
    done
) &
RSS_PID=$!

echo "[soak] wrk -t$THR -c$CON -d${DUR}s $URL"
wrk -t"$THR" -c"$CON" -d"${DUR}s" "$URL" | tee "$WRK_LOG"

# Terminate samplers / server
kill $RSS_PID 2>/dev/null || true
sleep 1
if ! kill -0 $PID 2>/dev/null; then
    echo "[FAIL] server exited during soak" >&2
    exit 1
fi

# -- Gate evaluation --
FAIL=0

# 2. server log scan
if grep -qE "SIGSEGV|SIGABRT|\[GC-BUG\]|\[D1-POST-MARK\] UNMARKED" "$SRV_LOG"; then
    echo "[FAIL] server log has crash/GC-bug markers" >&2
    grep -nE "SIGSEGV|SIGABRT|\[GC-BUG\]|\[D1-POST-MARK\] UNMARKED" "$SRV_LOG" | head -3
    FAIL=1
fi

# 3. HTTP non-2xx rate
NON2XX=$(awk '/Non-2xx or 3xx responses:/{print $NF}' "$WRK_LOG")
NON2XX=${NON2XX:-0}
if [ "$NON2XX" -gt 0 ]; then
    echo "[FAIL] $NON2XX non-2xx responses (container leak — check Phase 0 audit)" >&2
    FAIL=1
fi

# 4. RSS ratio t=DUR / t=180s  (compare 10-sample windows around 180 and DUR)
EARLY_RSS=$(awk 'NR<=18 && NR>=15 {print $2}' "$RSS_LOG" | sort -n | head -1)
LATE_RSS=$(tail -5 "$RSS_LOG" | sort -n | tail -1 | awk '{print $2}')
EARLY_RSS=${EARLY_RSS:-0}
LATE_RSS=${LATE_RSS:-0}
if [ "$EARLY_RSS" -gt 0 ]; then
    echo "[info] RSS early(t~180s)=${EARLY_RSS} kB  late(t~${DUR}s)=${LATE_RSS} kB"
    LIMIT=$((EARLY_RSS * 2))
    if [ "$LATE_RSS" -gt "$LIMIT" ]; then
        echo "[FAIL] RSS growth > 2x: $LATE_RSS > 2 * $EARLY_RSS ($LIMIT)" >&2
        FAIL=1
    fi
fi

if [ "$FAIL" -eq 0 ]; then
    echo "[PASS] soak ${DUR}s: server alive, 0 non-2xx, RSS within 2x"
fi
exit $FAIL
