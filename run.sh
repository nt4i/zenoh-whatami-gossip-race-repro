#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_COMMIT="173b1220c2ab59cc22c82bfc6c95ac9971ff213b"
REPO_URL="https://github.com/eclipse-zenoh/zenoh.git"
WORK_ROOT="$SCRIPT_DIR/.work"
mkdir -p "$WORK_ROOT"
RUN_DIR="$(mktemp -d "$WORK_ROOT/run.XXXXXXXX")"
ZENOH_DIR="$RUN_DIR/zenoh"
BEFORE_LOG="$RUN_DIR/before.log"
AFTER_LOG="$RUN_DIR/after.log"

echo "Cloning eclipse-zenoh at $BASE_COMMIT ..."
git -c core.longpaths=true clone --quiet --no-checkout "$REPO_URL" "$ZENOH_DIR"
git -c core.longpaths=true -C "$ZENOH_DIR" checkout --quiet "$BASE_COMMIT"

echo "Adding the deterministic regression test ..."
git -C "$ZENOH_DIR" apply "$SCRIPT_DIR/regression-test.patch"

TEST_ARGS=(
    test -p zenoh --features test --lib
    net::protocol::network::tests::test_reintroduced_node_role_is_filled_by_its_own_linkstate
    -- --exact --nocapture
)

echo "Running against the unmodified base (failure is expected) ..."
set +e
(cd "$ZENOH_DIR" && cargo "${TEST_ARGS[@]}" >"$BEFORE_LOG" 2>&1)
BEFORE_EXIT=$?
set -e

if [[ "$BEFORE_EXIT" -eq 0 ]]; then
    echo "The regression unexpectedly passed before the fix. See $BEFORE_LOG" >&2
    exit 1
fi
if ! grep -Fq 'left: None' "$BEFORE_LOG" || ! grep -Fq 'right: Some(Router)' "$BEFORE_LOG"; then
    cat "$BEFORE_LOG" >&2
    echo "The baseline failed for an unexpected reason. See $BEFORE_LOG" >&2
    exit 1
fi
echo "Confirmed: baseline leaves whatami as None. Log: $BEFORE_LOG"

build_daemon() {
    (cd "$ZENOH_DIR" && cargo build --release -p zenohd -p zenoh-plugin-rest)
}

build_admin_json_helper() {
    local example_dir="$ZENOH_DIR/zenoh/examples"
    mkdir -p "$example_dir"
    cp "$SCRIPT_DIR/adminspace-json.rs" "$example_dir/adminspace-json.rs"
    (cd "$ZENOH_DIR" && cargo build --release -p zenoh --example adminspace-json)
    ADMIN_JSON="$ZENOH_DIR/target/release/examples/adminspace-json"
    if [[ -f "$ADMIN_JSON.exe" ]]; then ADMIN_JSON="$ADMIN_JSON.exe"; fi
    if [[ ! -f "$ADMIN_JSON" ]]; then
        echo "Could not find the built Admin Space JSON helper." >&2
        exit 1
    fi
}

find_artifacts() {
    ZENOH_BIN="$ZENOH_DIR/target/release/zenohd"
    REST_PLUGIN=""
    for candidate in \
        "$ZENOH_DIR/target/release/zenohd.exe" \
        "$ZENOH_DIR/target/release/zenoh_plugin_rest.dll" \
        "$ZENOH_DIR/target/release/libzenoh_plugin_rest.so" \
        "$ZENOH_DIR/target/release/libzenoh_plugin_rest.dylib"; do
        if [[ -f "$candidate" ]]; then
            if [[ "$candidate" == *zenohd.exe ]]; then ZENOH_BIN="$candidate"; fi
            if [[ "$candidate" == *zenoh_plugin_rest.dll || "$candidate" == *libzenoh_plugin_rest.so || "$candidate" == *libzenoh_plugin_rest.dylib ]]; then
                REST_PLUGIN="$candidate"
            fi
        fi
    done
    if [[ ! -f "$ZENOH_BIN" || ! -f "$REST_PLUGIN" ]]; then
        echo "Could not find the built zenohd binary or REST plugin." >&2
        exit 1
    fi
}

echo "Building unmodified zenohd and REST plugin ..."
build_daemon
build_admin_json_helper
find_artifacts
BASE_FAILURE_FOUND=no
for trial in $(seq 1 10); do
    RESULT="$(bash "$SCRIPT_DIR/process-repro.sh" before "$ZENOH_BIN" "$REST_PLUGIN" "$RUN_DIR" "$trial" "$ADMIN_JSON")"
    printf '%s\n' "$RESULT"
    if [[ "$RESULT" == *"direct_C_B=no"* ]]; then
        BASE_FAILURE_FOUND=yes
        break
    fi
done
if [[ "$BASE_FAILURE_FOUND" != yes ]]; then
    echo "No unconnected baseline trial in 10 attempts; continuing with the fixed build for comparison."
fi

echo "Applying the one-line PR fix and rerunning ..."
git -C "$ZENOH_DIR" apply "$SCRIPT_DIR/whatami-fix.patch"
(cd "$ZENOH_DIR" && cargo "${TEST_ARGS[@]}" >"$AFTER_LOG" 2>&1) || {
    cat "$AFTER_LOG" >&2
    echo "The regression did not pass with the fix. See $AFTER_LOG" >&2
    exit 1
}
cat "$AFTER_LOG"
echo "Confirmed: fixed source stores Some(Router). Logs are in $RUN_DIR"

echo "Building fixed zenohd and REST plugin ..."
build_daemon
find_artifacts
for trial in 1 2 3 4 5; do
    bash "$SCRIPT_DIR/process-repro.sh" after "$ZENOH_BIN" "$REST_PLUGIN" "$RUN_DIR" "$((trial + 10))" "$ADMIN_JSON"
done
if [[ "$BASE_FAILURE_FOUND" != yes ]]; then
    echo "The deterministic regression test passed, but no unconnected baseline process trial was observed. See $RUN_DIR" >&2
    exit 1
fi
echo "The unconnected baseline case and all fixed process trials were observed. Logs and Admin Space snapshots are in $RUN_DIR"
