#!/bin/bash

# Scheduler profile: servers park for batched CQE reaping (override with
# FIBERUS_PROFILE=latency for A/B against the game-tuned idle behavior)
export FIBERUS_PROFILE=${FIBERUS_PROFILE:-server}
# crash_test.sh — Automated warp10 crash reproduction + validation script
#
# Usage: ./crash_test.sh [duration_sec] [build_mode] [wrk_threads] [wrk_connections]
#   duration_sec:    wrk test duration (default: 10)
#   build_mode:      "release" or "debug" (default: release)
#   wrk_threads:     wrk -t value (default: 2)
#   wrk_connections: wrk -c value (default: 10)
#
# Output: /tmp/warp10_crash_test_<timestamp>/
#   gdb.log        — full GDB backtrace (if crash)
#   server.log     — server stderr
#   wrk.log        — wrk output
#   perf.data      — perf profile (if available)
#   summary.txt    — PASS/FAIL with key metrics

set -euo pipefail

DURATION="${1:-10}"
BUILD_MODE="${2:-release}"
WRK_THREADS="${3:-2}"
WRK_CONNECTIONS="${4:-10}"
# 5th arg: "gdb" (default) or "rr" — rr records a deterministic-replay trace
# so the crash can be inspected via `rr replay <trace>` afterward. Requires
# nmi_watchdog=0 and perf_event_paranoid <=1.
RUNNER="${5:-gdb}"
PORT=8080
URL="http://127.0.0.1:${PORT}/api/v1/status"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="${SCRIPT_DIR}/bin/Main"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTDIR="/tmp/warp10_crash_test_${TIMESTAMP}"
CRASH_SIGNAL_REGEX='received signal SIG(SEGV|ABRT|BUS|ILL|FPE)|Program terminated with signal SIG(SEGV|ABRT|BUS|ILL|FPE)'

mkdir -p "${OUTDIR}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Warp10 Crash Test ===${NC}"
echo "Duration: ${DURATION}s, Build: ${BUILD_MODE}, wrk: -t${WRK_THREADS} -c${WRK_CONNECTIONS}"
echo "Output: ${OUTDIR}"

# --- Build ---
echo ""
echo "Building ${BUILD_MODE}..."
if ! make cache_clear -C "${SCRIPT_DIR}" > "${OUTDIR}/build.log" 2>&1; then
    echo -e "${RED}cache_clear FAILED${NC}"
    tail -5 "${OUTDIR}/build.log"
    exit 1
fi
if ! make "${BUILD_MODE}" -C "${SCRIPT_DIR}" >> "${OUTDIR}/build.log" 2>&1; then
    echo -e "${RED}BUILD FAILED${NC}"
    tail -20 "${OUTDIR}/build.log"
    exit 1
fi
echo -e "${GREEN}Build OK${NC}"

# --- Kill any existing server ---
pkill -9 -f "basic/bin/Main" 2>/dev/null || true
sleep 1

# --- Start server under chosen runner ---
echo ""
if [ "${RUNNER}" = "rr" ]; then
    echo "Starting server under rr record..."
    # Pin to P-cores (0-11). i9-12900H exposes cpu_core/branches on P-cores
    # and cpu_atom/branches on E-cores (12-19); rr 5.7.0 hardcodes the P-core
    # event so unpinned scheduling onto an E-core yields "Got 0 branch events".
    taskset -c 0-11 rr record -o "${OUTDIR}/rr_trace" "${BINARY}" > "${OUTDIR}/server.log" 2>&1 &
    GDB_PID=$!
    echo "rr PID: ${GDB_PID}"
else
    echo "Starting server under GDB..."
    gdb -batch \
        -ex "set pagination off" \
        -ex "set print thread-events off" \
        -ex "handle SIGPIPE nostop noprint pass" \
        -ex "handle SIGTERM nostop print pass" \
        -ex "run" \
        -ex "echo \n=== CRASH ===\n" \
        -ex "bt full" \
        -ex "echo \n=== ALL THREADS ===\n" \
        -ex "thread apply all bt" \
        -ex "quit" \
        "${BINARY}" > "${OUTDIR}/gdb.log" 2>"${OUTDIR}/server.log" &
    GDB_PID=$!
    echo "GDB PID: ${GDB_PID}"
fi

# Wait for server ready
READY=false
for i in $(seq 1 30); do
    if curl -s --max-time 1 "${URL}" > /dev/null 2>&1; then
        echo -e "${GREEN}Server ready after ${i}s${NC}"
        READY=true
        break
    fi
    # Check if GDB already exited (immediate crash)
    if ! kill -0 "${GDB_PID}" 2>/dev/null; then
        echo -e "${RED}Server died during startup${NC}"
        break
    fi
    sleep 1
done

if [ "${READY}" = false ]; then
    echo -e "${RED}Server failed to start within 30s${NC}"
    wait "${GDB_PID}" 2>/dev/null || true
    if grep -qE "${CRASH_SIGNAL_REGEX}" "${OUTDIR}/gdb.log" 2>/dev/null; then
        echo ""
        echo "=== Crash signal ==="
        grep -m 1 -E "${CRASH_SIGNAL_REGEX}" "${OUTDIR}/gdb.log"
        echo "=== Crash backtrace ==="
        grep -A 30 -E "${CRASH_SIGNAL_REGEX}" "${OUTDIR}/gdb.log" | head -35
    fi
    echo -e "\n${RED}RESULT: FAIL (startup crash)${NC}"
    echo "FAIL: startup crash" > "${OUTDIR}/summary.txt"
    exit 1
fi

# Get actual server PID (child of GDB)
SERVER_PID=$(pgrep -P "${GDB_PID}" -f Main 2>/dev/null | head -1 || true)
if [ -z "${SERVER_PID}" ]; then
    # Fallback: find any Main process
    SERVER_PID=$(pgrep -f "basic/bin/Main" 2>/dev/null | head -1 || true)
fi
echo "Server PID: ${SERVER_PID:-unknown}"

# --- Optional: attach perf ---
PERF_PID=""
if [ -n "${SERVER_PID}" ] && command -v perf &>/dev/null; then
    PERF_DURATION=$((DURATION + 5))
    perf record -g -F 999 -p "${SERVER_PID}" -o "${OUTDIR}/perf.data" -- sleep "${PERF_DURATION}" &>/dev/null &
    PERF_PID=$!
    echo "Perf recording for ${PERF_DURATION}s (PID: ${PERF_PID})"
fi

# --- Run wrk ---
echo ""
echo "Running wrk -t${WRK_THREADS} -c${WRK_CONNECTIONS} -d${DURATION}s ${URL}"
wrk -t"${WRK_THREADS}" -c"${WRK_CONNECTIONS}" -d"${DURATION}s" --latency "${URL}" > "${OUTDIR}/wrk.log" 2>&1 || true
echo "---"
cat "${OUTDIR}/wrk.log"
echo "---"

# --- Check if server survived ---
sleep 2
CRASHED=false
ALIVE=false

if kill -0 "${GDB_PID}" 2>/dev/null; then
    # GDB still running — try a request
    if curl -s --max-time 3 "${URL}" > /dev/null 2>&1; then
        ALIVE=true
        echo -e "${GREEN}Server still alive after load test${NC}"
    else
        echo -e "${YELLOW}Server unresponsive (may be stuck in GC)${NC}"
        # Give it a few more seconds
        sleep 5
        if curl -s --max-time 3 "${URL}" > /dev/null 2>&1; then
            ALIVE=true
            echo -e "${GREEN}Server recovered${NC}"
        fi
    fi
    # Send TERM for clean shutdown
    if [ -n "${SERVER_PID}" ]; then
        kill -TERM "${SERVER_PID}" 2>/dev/null || true
    fi
    sleep 3
    if [ "${RUNNER}" = "rr" ]; then
        # rr must flush its trace metadata; SIGTERM lets it run finalization.
        # SIGKILL leaves an `incomplete` marker which makes replay unusable.
        kill -TERM "${GDB_PID}" 2>/dev/null || true
        for _wait_i in 1 2 3 4 5; do
            kill -0 "${GDB_PID}" 2>/dev/null || break
            sleep 1
        done
        kill -9 "${GDB_PID}" 2>/dev/null || true
    else
        kill -9 "${GDB_PID}" 2>/dev/null || true
    fi
    wait "${GDB_PID}" 2>/dev/null || true
else
    # GDB already exited — check if it was a crash
    wait "${GDB_PID}" 2>/dev/null || true
fi

# Wait for perf
if [ -n "${PERF_PID}" ]; then
    kill -INT "${PERF_PID}" 2>/dev/null || true
    wait "${PERF_PID}" 2>/dev/null || true
fi

# --- rr post-processing: replay the captured trace to produce a gdb.log
# equivalent so the rest of this script's analysis works unchanged. ---
if [ "${RUNNER}" = "rr" ] && [ -d "${OUTDIR}/rr_trace" ] && [ -f "${OUTDIR}/rr_trace/version" ]; then
    echo "Running rr replay to extract crash backtrace..."
    rr replay "${OUTDIR}/rr_trace" -- \
        -batch \
        -ex "set pagination off" \
        -ex "continue" \
        -ex "echo \n=== CRASH ===\n" \
        -ex "bt full" \
        -ex "echo \n=== ALL THREADS ===\n" \
        -ex "thread apply all bt" \
        -ex "quit" \
        > "${OUTDIR}/gdb.log" 2>&1 || true
fi

# --- Analyze results ---
echo ""

# Check for crash signature in GDB output
if grep -qE "${CRASH_SIGNAL_REGEX}" "${OUTDIR}/gdb.log" 2>/dev/null; then
    CRASHED=true
fi

# Check for ARRAY_BAD_DATA in server log
BAD_DATA_COUNT=0
if [ -f "${OUTDIR}/server.log" ]; then
    BAD_DATA_COUNT=$(grep -c "ARRAY_BAD_DATA" "${OUTDIR}/server.log" 2>/dev/null || true)
    BAD_DATA_COUNT=${BAD_DATA_COUNT:-0}
fi

# Check for SIGSEGV in server log
SIGSEGV_COUNT=0
if [ -f "${OUTDIR}/server.log" ]; then
    SIGSEGV_COUNT=$(grep -c "SIGSEGV\|CRASH DETECTED" "${OUTDIR}/server.log" 2>/dev/null || true)
    SIGSEGV_COUNT=${SIGSEGV_COUNT:-0}
fi

# Extract wrk metrics
REQ_SEC=$(grep "Requests/sec:" "${OUTDIR}/wrk.log" 2>/dev/null | awk '{print $2}' || echo "0")
NON_2XX=$(grep "Non-2xx" "${OUTDIR}/wrk.log" 2>/dev/null | awk '{print $NF}' || echo "0")
ERRORS=$(grep "Socket errors:" "${OUTDIR}/wrk.log" 2>/dev/null || echo "none")

# Extract perf top function
PERF_TOP=""
if [ -f "${OUTDIR}/perf.data" ]; then
    PERF_TOP=$(perf report -i "${OUTDIR}/perf.data" --stdio --no-children -g none --percent-limit 5 2>/dev/null | \
               grep -E "^\s+[0-9]+\.[0-9]+%" | head -5 || echo "N/A")
fi

# --- Summary ---
{
    echo "=== Warp10 Crash Test Summary ==="
    echo "Date: $(date)"
    echo "Build: ${BUILD_MODE}"
    echo "Duration: ${DURATION}s"
    echo ""
    echo "--- Status ---"
    echo "Crashed: ${CRASHED}"
    echo "Server alive after test: ${ALIVE}"
    echo "ARRAY_BAD_DATA count: ${BAD_DATA_COUNT}"
    echo "SIGSEGV count: ${SIGSEGV_COUNT}"
    echo ""
    echo "--- Performance ---"
    echo "Requests/sec: ${REQ_SEC}"
    echo "Non-2xx responses: ${NON_2XX}"
    echo "Socket errors: ${ERRORS}"
    echo ""
    if [ -n "${PERF_TOP}" ]; then
        echo "--- Perf Top Functions ---"
        echo "${PERF_TOP}"
        echo ""
    fi
    if [ "${CRASHED}" = true ]; then
        echo "--- Crash signal ---"
        grep -m 1 -E "${CRASH_SIGNAL_REGEX}" "${OUTDIR}/gdb.log" 2>/dev/null || echo "N/A"
        echo ""
        echo "--- Crash Backtrace (first 30 lines) ---"
        grep -A 30 -E "${CRASH_SIGNAL_REGEX}" "${OUTDIR}/gdb.log" 2>/dev/null | head -35
        echo ""
        echo "RESULT: FAIL"
    elif [ "${BAD_DATA_COUNT}" -gt 0 ]; then
        echo "RESULT: FAIL (ARRAY_BAD_DATA detected)"
    elif [ "${ALIVE}" = true ] && { [ "${NON_2XX}" = "0" ] || [ -z "${NON_2XX}" ]; }; then
        echo "RESULT: PASS"
    elif [ "${ALIVE}" = true ]; then
        echo "RESULT: WARN (server alive but ${NON_2XX} non-2xx responses)"
    else
        echo "RESULT: FAIL (server died)"
    fi
} | tee "${OUTDIR}/summary.txt"

echo ""
echo "Full logs: ${OUTDIR}/"

# Exit code
if [ "${CRASHED}" = true ] || [ "${BAD_DATA_COUNT}" -gt 0 ]; then
    exit 1
elif [ "${ALIVE}" = true ]; then
    exit 0
else
    exit 1
fi
