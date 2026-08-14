# This is a fork

Upstream: **[Loriage/BeszelBar](https://github.com/Loriage/BeszelBar)** — MIT,
Copyright (c) 2025 Loriage. Forked at commit
[`8a0e3c7`](https://github.com/Loriage/BeszelBar/commit/8a0e3c7123853f5c312aebd8dfaf083d584484a2)
(also recorded in `UPSTREAM_COMMIT`). Upstream's project layout, `build.sh` and
`project.yml` are left as they were, and its README is preserved verbatim as
`UPSTREAM_README.md`. This file describes only what was added on top.

Three things were removed, all for the same reason — they belong to the original
author, not to a fork:

- `.github/FUNDING.yml` would put a sponsor button on this repository soliciting
  on their behalf.
- `homebrew/Casks/beszelbar.rb.template` and `scripts/release-cask.sh` publish to
  their Homebrew tap.
- `scripts/sign-and-notarize.sh` signs with their Developer ID.

None of them could work here, and leaving scripts around that cannot work invites
someone to run them. Credit is given in the README and the LICENSE instead.

## Why

Upstream reads everything from a Beszel hub. That is the right design until the
machine hosting the hub goes down, at which point the menu bar shows nothing —
including nothing about the machines that are still perfectly healthy.

This fork adds a second data path that does not involve the hub at all.

## What was added

All new code lives in `Sources/SSH/`, so the diff against upstream stays legible:

| File | Purpose |
|---|---|
| `SSHTarget.swift` | A machine reachable without the hub, plus its storage and the `DataSource` enum. |
| `AgentSnapshot.swift` | Decodes `beszel-agent stats` output and maps it onto the hub's shapes. |
| `SSHStatsService.swift` | Runs the command per target in parallel, over SSH or locally. |
| `SSHTargetsView.swift` | The Settings → SSH pane. |

Changes to upstream files were kept as small as possible:

| File | Change |
|---|---|
| `App/AppState.swift` | Fallback logic in `loadSystems()`, `loadFromSSH()`, SSH target management, the `sshDirectModeEnabled` switch, and a `dataSource` guard on the three hub-only loaders. |
| `App/SettingsView.swift` | One new tab case. |
| `Menu/MenuBuilder.swift` | A banner naming whichever source is live; the **SSH Direct Mode** row under *Refresh Now*; `build` became `populate`; the empty state now accounts for SSH-only setups. |
| `Menu/Views/MenuActionRow.swift` | New file. A menu row that acts on a click without closing the menu. |
| `App/AppDelegate.swift` | One menu for the life of the app, refilled on open, plus the timer that keeps the action rows current while it is held open. |
| `Menu/Views/MenuHeaderView.swift` | Title and subtitle. |
| `App/SettingsView.swift` (About) | Points at this fork; the original author's copyright notice stays. |

**Building your own copy?** The header subtitle is hardcoded in
`Sources/Menu/Views/MenuHeaderView.swift` — one string, one line. Upstream showed
the selected hub's name there, if you would rather have that back.

## The mapping was almost free

Upstream's `SystemInfo` uses the same short keys the agent emits (`cpu`, `mp`,
`dp`, `la`, `sv`, `efs`…) because the hub stores the agent's payload more or less
verbatim. So agent JSON decodes straight into the existing model, and the menu
renders SSH-sourced data with no view changes at all.

Two places where it is not free, both handled honestly rather than papered over:

- **`Details`** carries no JSON tags upstream, so over this path it arrives under
  Go field names (`Hostname`, `Cores`, …) and needs its own `CodingKeys`.
- **Containers** lose health, status and image — upstream marks them `json:"-"`,
  so they only travel to the hub over CBOR. They are reported as unknown. Showing
  "healthy" for a container whose health we never received would be a lie.

## Behaviour

- Hub answers → identical to upstream. SSH is never contacted.
- Hub fails → SSH targets are polled, the menu says **⚠︎ Hub erişilemiyor — SSH**
  with the underlying error, and alerts are cleared. Stale alerts left on screen
  would read as current, and this path has no alerting at all.
- A target that cannot be reached is shown as **down**, not dropped. A missing row
  reads as "nothing wrong here", which is the opposite of the truth.
- Hub recovers → normal service on the next refresh, automatically.
- No hub configured → SSH is used directly rather than treated as a fallback.

The fallback defaults to **on**. A safety net nobody remembered to enable is not
a safety net.

## Two ways to end up on SSH

The fallback above reacts to a hub that stopped answering. **SSH Direct Mode** is
the other reason to be on this path: the user asked. It sits in the menu under
*Refresh Now*, and on the Settings → SSH pane beside the fallback switch.

- Turning it on stops the hub being contacted at all — not even to find out
  whether it is healthy. Nothing can turn it back off but you.
- The menu says which of the two is live: **⚠︎ Hub unreachable — SSH** carries the
  hub's error, **SSH Direct — hub bypassed** carries none, because nothing broke.
  Both say the same thing about history and alerts, which are missing either way.
- It defaults to **off** and stays where you left it. The opposite default to the
  fallback, for the opposite reason: silently bypassing a working hub would cost
  history and alerts with nobody having asked for that.
- The item is inert with no targets configured, and removing the last target ends
  the mode — a direct mode with nothing to read can only report emptiness.

Switching it off refetches details, alerts and containers rather than waiting for
a timer. Those three sit out the whole time SSH is carrying the app, so what is on
screen at that moment all came from the other path.

## The menu stays open

*Refresh Now* and *SSH Direct Mode* both act on the menu you are looking at, and
both used to close it — you asked to see something and the thing you would have
seen it in went away.

Two separate causes, both fixed:

- **NSMenu closes whenever an item's action fires.** There is no flag for this. An
  item with a *view* never sends its action — the view gets the click instead —
  so those two rows are views now (`MenuActionRow`), which means drawing the
  title, icon, checkmark and hover highlight that AppKit was drawing before.
- **The menu was being replaced while open.** Every observed change rebuilt it
  and assigned it to the status item, which takes the open one down. It is now
  built once and refilled in `menuNeedsUpdate`, the moment AppKit provides for
  exactly this.

An open menu runs its own event loop, and observation gets no turn inside it, so
a 0.35s timer in `.common` mode nudges those rows while the menu is up — without
it the row reading "Refreshing…" would still read that long after the numbers
landed. Everything else in the menu is what it was when you opened it; the rows
are rebuilt on the next opening.

⌘R still refreshes, and still closes the menu. A key equivalent closing a menu is
what a key equivalent does; a click is not.

## Requirements

Every target needs an agent supporting the `stats` subcommand — see
[`agent-patch/`](agent-patch/). Stock Beszel agents do not have it.

## Building without Xcode

`build-spm.sh` compiles with the Command Line Tools and assembles the `.app`
bundle by hand, because upstream's `xcodebuild` path needs a full Xcode install.
The bundle is ad-hoc signed: enough for a stable identity across rebuilds, not a
Developer ID signature, so Gatekeeper will still prompt on first launch.

The one thing it gives up is the compiled asset catalog — `actool` ships with
Xcode — so the icon is built with `iconutil` instead. For a menu bar app that
icon is rarely seen.

Output goes to `.dist/`, not upstream's `build/Release/`. Spotlight indexes any
`.app` bundle it can see, so a build sitting in a visible directory means the app
matches twice in search — the installed copy and the build output — and picking
the wrong one runs stale code. Spotlight skips dot directories. `--install` copies
the bundle to `/Applications`, stopping a running instance first.
