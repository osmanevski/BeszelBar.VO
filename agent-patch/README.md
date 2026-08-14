# The `stats` patch

Adds one subcommand to the Beszel agent:

```
beszel-agent stats [window]    # sample once, print JSON, exit
```

No daemon, no listening port, nothing resident. It runs when something asks it to
and then goes away, which is what makes it safe to invoke over SSH on demand.

## What it touches

Two files, 35 added lines, nothing removed or rewritten:

| File | Change |
|---|---|
| `agent/snapshot.go` | New. Exports `Snapshot(sampleWindow)`, because upstream's `gatherStats()` is unexported and the command lives in a different package. |
| `internal/cmd/agent/agent.go` | Adds the `stats` case to the existing subcommand switch, plus `handleStats()`. |

Both changes are additive, so rebasing onto a newer upstream should be routine.

## Why the sampling window exists

`agent/cpu.go` records the CPU counters in `init()`, when the process starts.
Upstream then runs for hours and every reading is a delta against a previous one
taken 60 seconds earlier.

A one-shot process has no such history. Gathering immediately would produce a
delta measured over the few milliseconds between `init()` and the first read —
arithmetically valid and completely meaningless. So `Snapshot()` waits first,
giving those counters an interval worth subtracting. Memory and disk are
point-in-time reads and are unaffected by the wait.

The default window is one second. Pass another to widen it:

```
beszel-agent stats 5s
```

A wider window is steadier and closer to what a dashboard shows; a narrower one
is more immediate and noisier.

## Why call upstream's collector instead of reading /proc

Reading `/proc` directly would have fewer moving parts and no patch at all. It
would also mean maintaining a second implementation of every formula — and the
moment your number and the panel's number disagree by half a point, you own an
investigation into which one is lying.

Calling the same collector makes that class of disagreement structurally
impossible. The numbers match the dashboard because they *are* the dashboard's
numbers, computed by the same code on the same machine.

What still differs is the window, not the method: a panel showing a 60-second
average will look calmer than a one-second sample of the same host.

## Building

```
./build.sh
```

Clones upstream at the pinned tag, applies the patch, and cross-compiles for
Linux (amd64/arm64), Windows (amd64) and macOS (arm64). Override the tag with
`UPSTREAM_TAG=v0.19.0 ./build.sh`.

Requires a Go toolchain. The checkout it creates is gitignored — upstream's code
is fetched, never redistributed here.

### Windows caveat

Upstream embeds a LibreHardwareMonitor build for temperature sensors, produced by
`dotnet build`. Rather than require the .NET SDK, the build script writes a
placeholder to satisfy `go:embed`. The component is opt-in (`LHM=true`) and off by
default, so the only loss is temperature sensors on Windows. CPU, memory, disk,
swap and load are unaffected.

Install the .NET SDK and run the `dotnet build` step from upstream's Makefile if
you want real sensor support.

## Deploying

Install the patched binary alongside the running agent rather than over it:

```
scp bin/beszel-agent-linux-amd64 host:/opt/beszel-agent/beszel-agent-stats
```

Two files means no service restart, and rolling back is deleting one of them. The
tradeoff is version drift — if you update the agent, rebuild this too, or the two
will be measuring with different code.

## Locking the key down

The client only ever needs to run one command, so the key it uses should not be
able to run anything else. Add to the target's `authorized_keys`:

```
command="/opt/beszel-agent/beszel-agent-stats stats",restrict ssh-ed25519 AAAA... stats-readonly
```

On Windows the file is `C:\ProgramData\ssh\administrators_authorized_keys` and the
command is the `.exe` path.

`restrict` disables port forwarding, agent forwarding, pty allocation and X11.
`command=` runs that command and only that command, whatever the client asks for.
Verify it took by asking for something else and watching stats come back anyway:

```
ssh -i ~/.ssh/nabiz_stats host 'whoami'    # prints JSON, not a username
```
