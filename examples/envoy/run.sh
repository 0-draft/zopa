#!/usr/bin/env bash
# End-to-end check: start Envoy with zopa.wasm as a proxy-wasm
# filter, hit it with curl, assert HTTP statuses. Exercises the real
# proxy-wasm ABI (configure, request_headers, send_local_response).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WASM="$ROOT/zig-out/bin/zopa.wasm"
TEMPLATE="$ROOT/examples/envoy/envoy.yaml"

if [[ ! -f "$WASM" ]]; then
    echo "missing $WASM -- run 'zig build' first" >&2
    exit 2
fi
if ! command -v envoy >/dev/null 2>&1; then
    echo "envoy not on PATH -- 'brew install envoy'" >&2
    exit 2
fi

PORT=${ZOPA_TEST_PORT:-10070}
ADMIN_PORT=${ZOPA_TEST_ADMIN_PORT:-9931}
# Envoy picks the bootstrap parser by file extension, so the
# generated config has to live under a fixed `envoy.yaml` name.
WORK=$(mktemp -d -t zopa.envoy.XXXXXX)
RUN_YAML="$WORK/envoy.yaml"
LOG="$WORK/envoy.log"
ENVOY_PID=

cleanup() {
    if [[ -n "$ENVOY_PID" ]] && kill -0 "$ENVOY_PID" 2>/dev/null; then
        kill "$ENVOY_PID" 2>/dev/null || true
        wait "$ENVOY_PID" 2>/dev/null || true
    fi
    if [[ "${KEEP_LOG:-0}" != "1" ]]; then
        rm -rf "$WORK"
    else
        echo "envoy log retained at $LOG"
    fi
}
trap cleanup EXIT

# Substitute placeholders. sed in BSD/macOS handles `s|a|b|g` fine.
sed \
    -e "s|__WASM_PATH__|$WASM|g" \
    -e "s|__PORT__|$PORT|g" \
    -e "s|__ADMIN_PORT__|$ADMIN_PORT|g" \
    "$TEMPLATE" > "$RUN_YAML"

envoy -c "$RUN_YAML" --log-level warn --component-log-level wasm:debug > "$LOG" 2>&1 &
ENVOY_PID=$!

# Wait until the admin /ready endpoint reports LIVE.
ready=0
for _ in $(seq 1 80); do
    if curl -sf "http://127.0.0.1:$ADMIN_PORT/ready" 2>/dev/null | grep -q LIVE; then
        ready=1
        break
    fi
    if ! kill -0 "$ENVOY_PID" 2>/dev/null; then
        echo "envoy died during startup" >&2
        cat "$LOG" >&2
        exit 1
    fi
    sleep 0.1
done
if [[ "$ready" != 1 ]]; then
    echo "envoy never reached LIVE" >&2
    cat "$LOG" >&2
    exit 1
fi

failed=0
check() {
    local name=$1 expected_status=$2
    shift 2
    local actual
    actual=$(curl -s -o /dev/null -w "%{http_code}" "$@" "http://127.0.0.1:$PORT/")
    if [[ "$actual" == "$expected_status" ]]; then
        echo "PASS  $name (HTTP $actual)"
    else
        echo "FAIL  $name: got HTTP $actual, expected $expected_status"
        failed=$((failed + 1))
    fi
}

# Policy in test/envoy.yaml: allow iff method == GET.
check "GET / -> 200 allow" 200 -X GET
check "POST / -> 403 deny" 403 -X POST
check "DELETE / -> 403 deny" 403 -X DELETE
check "GET / with headers -> 200 allow" 200 -X GET -H "X-User: kt"

if (( failed > 0 )); then
    echo
    echo "$failed test(s) failed; envoy log follows:" >&2
    cat "$LOG" >&2
    exit 1
fi
echo
echo "all tests passed"
