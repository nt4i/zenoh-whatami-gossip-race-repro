# Zenoh `whatami` regression reproducer

This reproduces the missing node-role assignment addressed by [zenoh#2827](https://github.com/eclipse-zenoh/zenoh/pull/2827), using three real `zenohd` processes.

All three routers have gossip autoconnect enabled for routers and use `autoconnect_strategy: "greater-zid"`. B and C are configured to connect to A. No B–C connection is configured. `greater-zid` allows only the router with the greater Zenoh ID to initiate the automatic connection.

```mermaid
sequenceDiagram
    participant A as Router A
    participant B as Router B
    participant C as Router C

    B->>A: Connect
    Note over A,B: A–B session established
    C->>A: Connect
    A-->>B: C's role-bearing state, then A's updated link state
    A-->>C: A's link state (which lists B), then B's own state
    C->>C: A's links add B to C's graph (whatami=None, sn=0)
    C->>C: Process B's newer self-announcement
    alt Base commit, C has the greater ID
        C->>C: whatami stays None, so C skips B
        Note over B,C: B is not allowed to initiate, so there is no direct B–C transport
    else Base commit, B has the greater ID
        B->>C: Autoconnect succeeds and masks C's skipped attempt
    else With PR #2827 change
        C->>C: Existing-node update assigns B.whatami = Router
        Note over B,C: The greater-ID router can now initiate the connection
    end
```

The process result depends on the randomly generated router IDs. On the base commit, the trial reproduces the missing B–C connection when C is the only router allowed to initiate. If B is allowed to initiate, its connection can mask C's `whatami` bug. The PR change makes the role available to C as well.

## Run

Requires Bash and Rust/Cargo 1.97.1 (pinned by Zenoh).

```bash
bash ./run.sh
```

The script builds Zenoh at the base commit and with the PR #2827 role-assignment change, runs the regression test, and runs up to ten base process trials to find the no-connection case. It then runs five process trials with the PR change. Logs and Admin Space snapshots are saved under `.work/`.

## Expected result

The script runs two checks: an internal regression test, then a three-process check.

### 1. Regression test

The test code is in [`regression-test.patch` lines 11–85](https://github.com/nt4i/zenoh-whatami-gossip-race-repro/blob/main/regression-test.patch#L11-L85). It reproduces the two updates C receives in the scenario: A's link state listing B, followed by B's own link state relayed through A. The test passes these updates directly to C's network state and checks B's stored role; it does not start `zenohd` processes.

1. A's update tells C that A is connected to B, but gives no role for B. The test checks that C records B with `whatami=None` and `sn=0` at [lines 66–67](https://github.com/nt4i/zenoh-whatami-gossip-race-repro/blob/main/regression-test.patch#L66-L67).
2. The test sends B's own update with `whatami=Router` and `sn=2` at [lines 70–82](https://github.com/nt4i/zenoh-whatami-gossip-race-repro/blob/main/regression-test.patch#L70-L82).
3. It reads `net.graph[b_idx].whatami` and expects `Some(Router)` at [line 85](https://github.com/nt4i/zenoh-whatami-gossip-race-repro/blob/main/regression-test.patch#L85).

| Build | Value read by the test | Result |
| --- | --- | --- |
| Base commit | `None` (expected `Some(Router)`) | Fails: the values differ. |
| With PR #2827 | `Some(Router)` | Passes: the values match. |

The process check below separately checks whether C establishes a direct B–C transport.

### 2. Process check

[`process-repro.sh`](process-repro.sh#L149) starts A, connects B to A, then connects C to A; it waits for both A–B and A–C transports before checking the result. It then:

1. Checks C's Admin Space link-state graph for B: `graph_has_B=yes` ([check](process-repro.sh#L159)).
2. Checks C's log to confirm A's link map caused C to add B: `B_added_from_A_links_at_C=yes` ([check](process-repro.sh#L178)).
3. Queries C's Admin Space for a direct B–C transport: `direct_C_B=no` or `yes` ([query](process-repro.sh#L173)).

A baseline reproduction is `graph_has_B=yes B_added_from_A_links_at_C=yes direct_C_B=no`. `run.sh` tries up to ten baseline trials because B's autoconnect can establish B–C first and mask C's skipped attempt. With PR #2827, all five trials must report `direct_C_B=yes`. These process checks do not expose `whatami`; the regression test above reads that field directly. Each trial saves its result, logs, and Admin Space snapshots under `.work/` ([snapshots](process-repro.sh#L170), [result](process-repro.sh#L188)).
