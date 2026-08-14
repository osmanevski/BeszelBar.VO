# nabiz — terminal client

Polls every configured machine in parallel and prints a compact view. No hub
involved: each host runs `beszel-agent stats` and hands back JSON.

```
./nabiz            # table
./nabiz --json     # raw, for feeding something else
```

```
  NABIZ  17:15:48  (hub yok — dogrudan SSH)

  ● Ubuntu Sunucu  host.example.net
      cpu   ████████··  82.2%   load 7.48 6.37 5.53 / 4c
      ram   ██████····  57.1%   3.30 / 5.79 GB   swap 0.66 / 1.88 GB
      disk  ████······  39.8%   21.7 / 57.1 GB
      up 8g 21s · 4 thread · 2 konteyner · 74 servis · 2.8s
```

## Setup

```
cp hosts.example.json hosts.local.json
```

Then edit it. `hosts.local.json` is gitignored — real addresses stay out of the
repository.

Each host needs an agent with the `stats` subcommand; see
[`../agent-patch/`](../agent-patch/).

## Notes

Python 3 standard library only — nothing to install.

**Speed.** Roughly 3 seconds cold, 1.5 warm. The floor is the agent's own
sampling window, which cannot be shortened without making the CPU figure
meaningless. Warm runs are faster because SSH connections are reused via
`ControlMaster`; `ssh_control_persist` controls how long they stay open.

**Parallel.** Wall time is the slowest host, not the sum. A host that is down
contributes an error line instead of holding up everything else.

**No fallback key.** If the restricted key fails, the run fails. Falling back to
a full-privilege key would quietly undo the point of restricting it, and a
failure here should be visible rather than papered over.

**Exit code** is 1 if any host failed, 0 otherwise — usable in a shell check.
