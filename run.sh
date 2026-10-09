#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_COMMIT="173b1220c2ab59cc22c82bfc6c95ac9971ff213b"
REPO_URL="https://github.com/eclipse-zenoh/zenoh.git"
TOOLCHAIN="${TOOLCHAIN:-1.97.1}"
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
    "+$TOOLCHAIN" test -p zenoh --features test --lib
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
    (cd "$ZENOH_DIR" && cargo "+$TOOLCHAIN" build --release -p zenohd -p zenoh-plugin-rest)
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
find_artifacts
for trial in 1 2 3 4 5; do
    bash "$SCRIPT_DIR/process-repro.sh" before "$ZENOH_BIN" "$REST_PLUGIN" "$RUN_DIR" "$trial"
done

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
    bash "$SCRIPT_DIR/process-repro.sh" after "$ZENOH_BIN" "$REST_PLUGIN" "$RUN_DIR" "$((trial + 10))"
done
echo "Both process variants passed. Before/after logs and Admin Space snapshots are in $RUN_DIR"
