# Zenoh `whatami` link-state regression reproducer

This repository demonstrates the missing role assignment fixed by [eclipse-zenoh/zenoh#2827](https://github.com/eclipse-zenoh/zenoh/pull/2827).

The reproducer applies a small test-only patch to the exact Zenoh base commit, then feeds `Network::link_states()` the triggering sequence directly. The sequence first registers B's per-link ID mapping, then processes A's link state with B only in A's `links` map. That creates B as a placeholder (`whatami: None`, `sn: 0`). B's newer self-announcement then updates that existing node. On the unmodified base, the final role remains `None`; with the PR's one-line assignment, it becomes `Some(Router)`.

This is a deterministic regression test of the actual router link-state code. A three-`zenohd` process experiment using the simple A-C-first, then B-to-A topology did **not** reproduce the issue in 10/10 runs on the base commit: A sends B's role-bearing state before its own links update in the same list, and C autoconnects B. The Admin Space link-state endpoint exposes the graph but does not expose the node's internal `whatami` field. For those reasons, this repository does not present that process topology or its REST graph as evidence of the bug.

## Requirements

- Bash (Git Bash on Windows, or Bash on Linux/macOS)
- Git
- Rust and Cargo; the default run uses Rust 1.97.1 (`rustup toolchain install 1.97.1` if needed)
- Network access to clone Zenoh and download Cargo dependencies

The tested source commit is `173b1220c2ab59cc22c82bfc6c95ac9971ff213b`, the base of PR #2827. Docker is not required.

## Run

From a clone of this repository, run:

```bash
bash ./run.sh
```

If Rust 1.97.1 is not installed but another compatible toolchain is available, select it with `TOOLCHAIN`:

```bash
TOOLCHAIN=stable bash ./run.sh
```

The script creates a fresh Zenoh clone under `.work/`, expects the baseline test to fail with `left: None` / `right: Some(Router)`, applies the PR fix, and requires the same test to pass. It keeps both logs in the generated run directory.

## Expected result

Before the fix:

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

## Pull request reply

> I added a deterministic reproducer at [nt4i/zenoh-whatami-gossip-race-repro](https://github.com/nt4i/zenoh-whatami-gossip-race-repro). It applies a test-only patch to the PR base commit and feeds `link_states()` the sequence that creates a reintroduced placeholder for B (`whatami: None`, `sn: 0`) before B's newer self-announcement arrives. The test fails on the unmodified base because B remains `None`, then passes with the one-line `node.whatami = Some(ls.whatami)` fix. I also tried the simple three-`zenohd` A-C-first topology; it did not reproduce in 10/10 runs, so I am not presenting that timing-sensitive setup as evidence.
