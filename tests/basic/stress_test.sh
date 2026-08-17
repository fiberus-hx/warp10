#!/bin/bash
# stress_test.sh - Stress test for Warp10 HTTP server
#
# Usage: ./stress_test.sh [duration] [gdb]
#   duration: test duration in seconds (default: 10)
#   gdb: "true" to run under GDB for crash debugging (default: false)

set -e

# Scheduler profile: servers park for batched CQE reaping (override with
# FIBERUS_PROFILE=latency for A/B against the game-tuned idle behavior)
export FIBERUS_PROFILE=${FIBERUS_PROFILE:-server}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
DURATION=${1:-10}
USE_GDB=${2:-false}
SERVER_LOG="/tmp/warp10_stress_server.log"
WRK_THREADS=${WRK_THREADS:-2}
WRK_CONNECTIONS=${WRK_CONNECTIONS:-10}
WRK_PATH=${WRK_PATH:-/api/v1/status}
PORT=8080

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Warp10 Stress Test ===${NC}"
echo "Duration: ${DURATION}s, GDB: ${USE_GDB}"
echo "wrk: threads=${WRK_THREADS}, connections=${WRK_CONNECTIONS}, path=${WRK_PATH}"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    pkill -9 -f "basic/bin/Main" 2>/dev/null || true
    pkill -9 gdb 2>/dev/null || true
}
trap cleanup EXIT

# Kill any existing instances
pkill -9 -f "basic/bin/Main" 2>/dev/null || true
sleep 1

# Check if binary exists
if [ ! -f "$BIN_DIR/Main" ]; then
    echo -e "${RED}ERROR: Binary not found at $BIN_DIR/Main${NC}"
    echo "Run 'make' or 'make release' first to build the server."
    exit 1
fi

# Start server
cd "$BIN_DIR"
echo "Starting server..."

if [ "$USE_GDB" = "true" ]; then
    echo "Running under GDB for crash debugging..."
    gdb -batch \
        -ex "set pagination off" \
        -ex "set print thread-events off" \
        -ex "handle SIGPIPE nostop noprint pass" \
        -ex "run" \
        -ex "echo \n=== CRASH DETECTED ===\n" \
        -ex "bt full" \
        -ex "echo \n=== ALL THREADS ===\n" \
        -ex "info threads" \
        -ex "echo \n=== THREAD BACKTRACES ===\n" \
        -ex "thread apply all bt full" \
        ./Main > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
else
    ./Main > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
fi
echo "Server output will be logged to: $SERVER_LOG"

# Wait for server to be ready (warp10 takes longer to start than the simple HTTP server)
echo "Waiting for server to start..."
for i in {1..20}; do
    if curl -s --max-time 1 "http://localhost:${PORT}/api/v1/status" > /dev/null 2>&1; then
        echo -e "${GREEN}Server is ready (PID: $SERVER_PID)${NC}"
        break
    fi
    if [ $i -eq 20 ]; then
        echo -e "${RED}ERROR: Server failed to start within 20 seconds${NC}"
        echo "Server log:"
        tail -20 "$SERVER_LOG" 2>/dev/null
        exit 1
    fi
    sleep 1
done

echo ""
echo "Running load test for ${DURATION}s..."
echo "---"

# Run load test
WRK_ARGS="-t${WRK_THREADS} -c${WRK_CONNECTIONS} -d${DURATION}s --latency"
wrk ${WRK_ARGS} "http://127.0.0.1:${PORT}${WRK_PATH}"

echo "---"
echo ""

# Wait a moment for any delayed crash
sleep 2

# Check if server survived
if kill -0 $SERVER_PID 2>/dev/null; then
    echo -e "${GREEN}SUCCESS: Server survived the load test${NC}"
    
    # Quick sanity check (allow a short drain period after wrk)
    SANITY_OK=0
    for i in {1..5}; do
        if curl -s --max-time 2 "http://localhost:${PORT}/api/v1/status" > /dev/null 2>&1; then
            SANITY_OK=1
            break
        fi
        sleep 1
    done
    if [ $SANITY_OK -eq 1 ]; then
        echo "Server is still responding to requests."
    else
        echo -e "${YELLOW}WARNING: Server is running but not responding${NC}"
    fi
    
    # Send TERM signal to get clean shutdown and stats
    echo ""
    echo "Sending TERM signal for clean shutdown..."
    kill -TERM $SERVER_PID 2>/dev/null || true
    for i in {1..3}; do
        if ! kill -0 $SERVER_PID 2>/dev/null; then
            break
        fi
        sleep 1
    done
    if kill -0 $SERVER_PID 2>/dev/null; then
        echo -e "${YELLOW}WARNING: Graceful shutdown timed out; forcing SIGKILL${NC}"
        kill -9 $SERVER_PID 2>/dev/null || true
        sleep 1
    fi
    
    echo ""
    echo "=== Server Log (last 50 lines) ==="
    tail -50 "$SERVER_LOG"
    echo "==================================="
    echo "Full log available at: $SERVER_LOG"
    
    exit 0
else
    wait $SERVER_PID 2>/dev/null
    EXIT_CODE=$?
    echo -e "${RED}FAILURE: Server crashed!${NC}"
    echo "Exit code: $EXIT_CODE"
    
    case $EXIT_CODE in
        139) echo "  -> Segmentation fault (SIGSEGV)" ;;
        134) echo "  -> Abort (SIGABRT)" ;;
        136) echo "  -> Floating point exception (SIGFPE)" ;;
        137) echo "  -> Killed (SIGKILL / OOM)" ;;
        *)   echo "  -> Unknown signal" ;;
    esac
    
    echo ""
    echo "=== Server Log ==="
    cat "$SERVER_LOG"
    echo "=================="
    
    if [ "$USE_GDB" != "true" ]; then
        echo ""
        echo "Tip: Run with GDB to get backtrace:"
        echo "  ./stress_test.sh $DURATION true"
    fi
    
    exit 1
fi
