# Zenoh `whatami` regression reproducer

This reproduces the missing node-role assignment addressed by [zenoh#2827](https://github.com/eclipse-zenoh/zenoh/pull/2827), using three real `zenohd` processes.

All three routers have gossip autoconnect enabled for routers and use `autoconnect_strategy: "greater-zid"`. B and C connect only to A through their configured `connect` endpoint; there is no configured B–C connection. `greater-zid` allows only the router with the greater Zenoh ID to initiate the automatic connection.

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
    C->>C: Create B placeholder (whatami=None, sn=0)
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

| Build | Regression test | Process result |
| --- | --- | --- |
| Base commit | Fails: `whatami` remains `None` instead of `Some(Router)` | May be `direct_C_B=no` or `yes`, depending on which router is allowed to initiate; the script looks for a `no` trial |
| With PR #2827 change | Passes | `direct_C_B=yes` |

The regression test reads `net.graph[b_idx].whatami` directly: it checks the placeholder (`None`, `sn: 0`) and then checks the value after B's own announcement. The process trial saves C's link-state and B–C transport Admin Space responses for inspection.
