#!/usr/bin/env bash
set -euo pipefail

VARIANT="${1:?usage: process-repro.sh before|after ZENOH_BIN REST_PLUGIN RUN_DIR TRIAL ADMIN_JSON}"
ZENOH_BIN="${2:?missing zenohd binary}"
REST_PLUGIN="${3:?missing REST plugin}"
RUN_DIR="${4:?missing artifact directory}"
TRIAL="${5:?missing trial number}"
ADMIN_JSON="${6:?missing Admin Space JSON helper}"
if [[ "$VARIANT" != before && "$VARIANT" != after ]]; then
    echo "Variant must be 'before' or 'after'." >&2
    exit 2
fi

PORT_BASE="$((17470 + TRIAL * 10))"
REST_BASE="$((18170 + TRIAL * 10))"
TRIAL_DIR="$RUN_DIR/process-$VARIANT-$TRIAL"
mkdir -p "$TRIAL_DIR"
A_PORT="$((PORT_BASE + 1))"
B_PORT="$((PORT_BASE + 2))"
C_PORT="$((PORT_BASE + 3))"
A_REST="$((REST_BASE + 1))"
B_REST="$((REST_BASE + 2))"
C_REST="$((REST_BASE + 3))"
A_LOCATOR="tcp/127.0.0.1:${A_PORT}"
B_LOCATOR="tcp/127.0.0.1:${B_PORT}"
C_LOCATOR="tcp/127.0.0.1:${C_PORT}"

cat >"$TRIAL_DIR/A.json5" <<EOF
{
  mode: "router",
  listen: { endpoints: ["${A_LOCATOR}"] },
  connect: { endpoints: [] },
  scouting: {
    multicast: { enabled: false },
    gossip: { enabled: true, multihop: true, autoconnect: { router: [] } }
  },
  adminspace: { enabled: true, permissions: { read: true, write: false } }
}
EOF
cat >"$TRIAL_DIR/B.json5" <<EOF
{
  mode: "router",
  listen: { endpoints: ["${B_LOCATOR}"] },
  connect: { endpoints: ["${A_LOCATOR}"] },
  scouting: {
    multicast: { enabled: false },
    gossip: { enabled: true, multihop: true, autoconnect: { router: [] } }
  },
  adminspace: { enabled: true, permissions: { read: true, write: false } }
}
EOF
cat >"$TRIAL_DIR/C.json5" <<EOF
{
  mode: "router",
  listen: { endpoints: ["${C_LOCATOR}"] },
  connect: { endpoints: ["${A_LOCATOR}"] },
  scouting: {
    multicast: { enabled: false },
    gossip: { enabled: true, multihop: true, autoconnect: { router: ["router"] } }
  },
  adminspace: { enabled: true, permissions: { read: true, write: false } }
}
EOF

admin_value() {
    local port="$1" operation="$2" locator="$3" owner="$4" peer="$5"
    local endpoint="http://localhost:${port}/@/**"

    curl --fail --silent --show-error --max-time 2 "$endpoint" |
        "$ADMIN_JSON" "$operation" "$locator" "$owner" "$peer"
}

if [[ "$OSTYPE" == msys* || "$OSTYPE" == mingw* || "$OSTYPE" == cygwin* ]]; then
    NATIVE_BIN="$(cygpath -w "$ZENOH_BIN")"
    NATIVE_PLUGIN="$(cygpath -m "$REST_PLUGIN")"
    NATIVE_ARGS=1
else
    NATIVE_BIN="$ZENOH_BIN"
    NATIVE_PLUGIN="$REST_PLUGIN"
    NATIVE_ARGS=0
fi

PIDS=()
stop_routers() {
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${PIDS[@]:-}"; do
        wait "$pid" 2>/dev/null || true
    done
}
trap stop_routers EXIT INT TERM

start_router() {
    local name="$1" rest_port="$2"
    if [[ "$NATIVE_ARGS" -eq 1 ]]; then
        MSYS2_ARG_CONV_EXCL='*' RUST_LOG='zenoh::net::protocol::network=trace' \
            "$NATIVE_BIN" --config "$(cygpath -w "$TRIAL_DIR/$name.json5")" \
            --plugin "rest:$NATIVE_PLUGIN" --rest-http-port "$rest_port" \
            >"$TRIAL_DIR/$name.log" 2>&1 &
    else
        RUST_LOG='zenoh::net::protocol::network=trace' \
            "$NATIVE_BIN" --config "$TRIAL_DIR/$name.json5" \
            --plugin "rest:$NATIVE_PLUGIN" --rest-http-port "$rest_port" \
            >"$TRIAL_DIR/$name.log" 2>&1 &
    fi
    PIDS+=("$!")
}

wait_for_id() {
    local port="$1" locator="$2" zid="" attempt
    for attempt in $(seq 1 80); do
        zid="$(admin_value "$port" id "$locator" "" "" 2>/dev/null || true)"
        if [[ -n "$zid" ]]; then
            printf '%s' "$zid"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

wait_for_transport() {
    local port="$1" owner="$2" peer="$3" attempt result
    for attempt in $(seq 1 80); do
        result="$(admin_value "$port" transport "" "$owner" "$peer" 2>/dev/null || true)"
        if [[ "$result" == yes ]]; then return 0; fi
        sleep 0.25
    done
    return 1
}

start_router A "$A_REST"
A_ID="$(wait_for_id "$A_REST" "$A_LOCATOR")" || { echo "Router A REST did not start" >&2; exit 1; }
start_router B "$B_REST"
B_ID="$(wait_for_id "$B_REST" "$B_LOCATOR")" || { echo "Router B REST did not start" >&2; exit 1; }
wait_for_transport "$B_REST" "$B_ID" "$A_ID" || { echo "B did not establish A-B before C started" >&2; exit 1; }
sleep 1
start_router C "$C_REST"
C_ID="$(wait_for_id "$C_REST" "$C_LOCATOR")" || { echo "Router C REST did not start" >&2; exit 1; }
wait_for_transport "$C_REST" "$C_ID" "$A_ID" || { echo "C did not establish C-A" >&2; exit 1; }

GRAPH="no"
for attempt in $(seq 1 40); do
    GRAPH="$(admin_value "$C_REST" graph "" "$C_ID" "$B_ID" 2>/dev/null || true)"
    [[ "$GRAPH" == yes ]] && break
    sleep 0.25
done
if [[ "$GRAPH" != yes ]]; then
    echo "C's Admin Space did not show B in the link-state graph; see $TRIAL_DIR" >&2
    exit 1
fi

admin_value "$C_REST" dump "" "" "" >"$TRIAL_DIR/C-adminspace.json"
DIRECT="no"
for attempt in $(seq 1 20); do
    DIRECT="$(admin_value "$C_REST" transport "" "$C_ID" "$B_ID")"
    [[ "$DIRECT" == yes ]] && break
    sleep 0.25
done
if ! grep -Fq "Add node (reintroduced) $B_ID" "$TRIAL_DIR/C.log"; then
    echo "C did not log B's reintroduced placeholder; see $TRIAL_DIR/C.log" >&2
    exit 1
fi

if [[ "$VARIANT" == before && "$DIRECT" != no ]]; then
    echo "Before: expected C not to autoconnect B, but direct transport exists." >&2
    exit 1
fi
if [[ "$VARIANT" == after && "$DIRECT" != yes ]]; then
    echo "After: expected C to autoconnect B, but direct transport is absent." >&2
    exit 1
fi

echo "$VARIANT trial $TRIAL: graph_has_B=yes direct_C_B=$DIRECT"
echo "  C trace: $TRIAL_DIR/C.log"
