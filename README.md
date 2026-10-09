# Zenoh `whatami` link-state regression reproducer

This repository demonstrates the missing role assignment fixed by [eclipse-zenoh/zenoh#2827](https://github.com/eclipse-zenoh/zenoh/pull/2827) with both real `zenohd` processes and a deterministic regression test of `Network::link_states()`.

The process reproducer launches three router daemons. A starts first, B connects to A, and then C connects to A. C receives A's initial full link-state list with A's entry first and B's entry second. A's `links` map mentions B, so C creates B as a placeholder (`whatami: None`, `sn: 0`) before it processes B's own newer state. On the base commit, C's node role remains unset and its autoconnect check skips B. After the PR's one-line assignment, C learns B's role and establishes a direct C-B transport.

Only C has router autoconnect enabled in this topology. B's autoconnect is disabled so B cannot initiate C-B itself and mask the missing attempt from C. The trial waits for the A-B session before starting C, then verifies the graph and direct transport through the Admin Space REST API. REST does not expose the internal `whatami` field, so the test combines the REST transport observation with C's `Add node (reintroduced)` trace; the in-memory regression test separately asserts the exact `None` to `Some(Router)` state.

## Requirements

- Bash
- Git
- Rust and Cargo; the default run uses Rust 1.97.1
- Python 3 (to inspect the Admin Space REST JSON)

## Run

From a clone of this repository, run:

```bash
bash ./run.sh
```

If Rust 1.97.1 is not installed but another compatible toolchain is available, select it with `TOOLCHAIN`:

```bash
TOOLCHAIN=stable bash ./run.sh
```

The script creates a fresh Zenoh clone under `.work/`, builds and runs the unmodified base, then applies the PR fix and repeats. It requires the internal regression test to fail before and pass after the fix, and runs the three-daemon topology five times for each build. The process trials save each daemon's trace and C's Admin Space snapshot in the generated run directory.

## Expected result

Before the fix, each process trial reports:

```text
before trial 1: graph_has_B=yes direct_C_B=no
```

C's log includes `Add node (reintroduced) <B-ZID>`. The snapshot is saved as `process-before-1/C-adminspace.json`.

After applying the fix, each process trial reports:

```text
after trial 11: graph_has_B=yes direct_C_B=yes
```

The direct C-B transport is visible under `@/<C-ZID>/session/transport/unicast/<B-ZID>` in the saved Admin Space snapshot.

The in-memory regression test also reports the exact field comparison. Before the fix:

```text
assertion `left == right` failed
  left: None
 right: Some(Router)
test ...test_reintroduced_node_role_is_filled_by_its_own_linkstate ... FAILED
```

After applying `whatami-fix.patch`:

```text
test ...test_reintroduced_node_role_is_filled_by_its_own_linkstate ... ok
test result: ok. 1 passed; 0 failed
```

The regression test asserts the intermediate placeholder state (`whatami: None`, `sn: 0`) before delivering B's own newer link state, then asserts the final role is `Some(Router)`. On the base commit, only that final assertion fails. The patch adds the same assignment proposed in PR #2827: `node.whatami = Some(ls.whatami);`.
