# Nabiz

A second way to see your machines, for when the first one is the thing that broke.

Nabiz does not replace [Beszel](https://github.com/henrygd/beszel). It sits beside
it and answers when the hub cannot.

## The problem

A monitoring hub is a single point of failure for the one job you cannot afford to
lose. Everything works until the machine hosting the hub goes down — and then you
lose the dashboard, the alerts, and any view of every *other* machine, all at the
moment you most need to look.

Moving the hub elsewhere does not fix this. It relocates the blind spot. Whatever
machine hosts the hub, that machine's death is the one death the hub cannot report.

## The approach

Give the fleet a second path with a different failure mode.

The hub stays primary and keeps doing what it is good at: history, graphs, alerts,
long-term trends. Alongside it, Nabiz reads each machine **directly over SSH**, with
no hub anywhere in the path. When the hub is healthy you never notice. When it is
not, you can still see every machine that is still alive — and a machine that has
genuinely died shows up as a refused connection, which is itself the answer.

What this path does *not* give you is history or alerting. Those live in the hub,
and no amount of SSH will conjure them. It answers exactly one question: what is
happening on these machines right now.

## What is here

| | |
|---|---|
| [`agent-patch/`](agent-patch/) | A 35-line patch adding a `stats` subcommand to the Beszel agent: sample once, print JSON, exit. |
| [`cli/`](cli/) | A terminal client that polls every machine in parallel and prints a compact view. |
| [`menubar/`](menubar/) | A fork of BeszelBar with automatic SSH fallback when the hub stops answering. |

## Built on

Nabiz is a small amount of work sitting on two projects that did the hard parts.
Both are MIT licensed and both deserve the credit:

**[henrygd/beszel](https://github.com/henrygd/beszel)** — the monitoring system:
agent, hub, collectors, dashboard. `agent-patch/` is a patch against v0.18.7, not a
fork; the upstream source is fetched at build time and never redistributed here.

**[Loriage/BeszelBar](https://github.com/Loriage/BeszelBar)** — the macOS menu bar
client for Beszel. `menubar/` **is** a fork, carrying upstream's source with our
changes on top. Upstream's README, structure and build script are left intact.

> BeszelBar's README declares MIT but the repository has no `LICENSE` file at the
> time of forking. The declaration is taken at face value. If you are the author
> and would rather this were handled differently, please open an issue.

## What we changed, and why

### 1. A one-shot mode for the agent

Upstream's agent is a long-running process that either dials the hub over
WebSocket or listens for the hub to connect over SSH. Both assume a hub.

The patch adds a third mode that assumes nothing: run, sample, print, exit. No
daemon, no port, no memory footprint when idle.

**The trap:** `agent/cpu.go` records CPU counters in `init()`, and every reading is
a delta against the previous sample. A one-shot process has no previous sample, so
gathering immediately yields a delta over a few milliseconds — arithmetically fine,
practically noise. `Snapshot()` waits a sampling window first. Memory and disk are
point-in-time reads and do not need it.

### 2. Upstream's collector, not our own

Reading `/proc` ourselves would have been less work and one less patch. We call
upstream's collector instead, deliberately.

The reason is not accuracy, it is consistency. Two independent implementations of
"percent memory used" will eventually disagree by half a point, and then somebody
has to work out which one is wrong. Calling the same code makes that impossible:
the numbers match the dashboard because they are computed by the dashboard's own
collector.

The remaining difference is the sampling window, not the method — a 60-second
average looks calmer than a one-second sample of the same machine.

### 3. Automatic fallback in the menu bar

The fork adds an SSH data source behind the same interface the hub API already
satisfied, so the menu did not need rewriting. The behaviour:

- Hub answers → everything as upstream, SSH untouched.
- Hub does not answer → poll the SSH targets, show live figures, and **say so** in
  the menu. Alerts are cleared rather than left on screen going stale, because
  alerts on this path do not exist and old ones would read as current.
- Hub recovers → back to normal on the next refresh, no intervention.

It also works with no hub configured at all, if SSH is all you want.

### 4. A build that does not need Xcode

Upstream builds with XcodeGen and `xcodebuild`, which require a full Xcode install.
`menubar/build-spm.sh` builds the same sources with the Swift compiler in the
Command Line Tools and assembles the `.app` bundle by hand.

Upstream's `build.sh` is untouched and still works if you have Xcode.

## Getting started

**1. Build and install the patched agent** on every machine you want to reach:

```
cd agent-patch && ./build.sh
scp ../bin/beszel-agent-linux-amd64 host:/opt/beszel-agent/beszel-agent-stats
```

Install it *alongside* the running agent, not over it — no restart needed, and
rollback is deleting a file.

**2. Lock down a key** so it can do nothing but report. On each target:

```
command="/opt/beszel-agent/beszel-agent-stats stats",restrict ssh-ed25519 AAAA... stats-readonly
```

Verify by asking for something else and watching stats come back regardless:

```
ssh -i ~/.ssh/nabiz_stats host 'whoami'    # prints JSON, not a username
```

**3a. Terminal client:**

```
cd cli
cp hosts.example.json hosts.local.json   # edit it
./nabiz
```

**3b. Menu bar app:**

```
cd menubar && ./build-spm.sh
open build/Release/BeszelBar.app
```

Add your machines under Settings → SSH.

## Honest limitations

- **No history, no alerts** on the SSH path. That is the hub's job and it stays the
  hub's job. This is a fallback for sight, not a replacement for monitoring.
- **Containers lose detail.** Health, status and image are `json:"-"` upstream —
  they reach the hub over CBOR only. Over SSH a container reports its name and
  resource use; health shows as unknown rather than being invented.
- **No temperature sensors on Windows**, unless you build with the .NET SDK. See
  [`agent-patch/README.md`](agent-patch/README.md).
- **Version drift.** The stats binary and the running agent are separate files. If
  you update one, rebuild the other.
- **The Mac has to be awake.** This is a pull model — it answers when you look. If
  you need to be *told* when something dies, you need a heartbeat service outside
  the fleet; nothing here does that.

## License

MIT. See [LICENSE](LICENSE), which carries the upstream copyright notices too.
