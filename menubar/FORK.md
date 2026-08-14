# This is a fork

Upstream: **[Loriage/BeszelBar](https://github.com/Loriage/BeszelBar)** — MIT,
Copyright (c) 2025 Loriage. Forked at commit
[`8a0e3c7`](https://github.com/Loriage/BeszelBar/commit/8a0e3c7123853f5c312aebd8dfaf083d584484a2)
(also recorded in `UPSTREAM_COMMIT`). Upstream's `README.md`, project layout and
`build.sh` are left as they were; this file describes only what was added on top.

Upstream's `.github/FUNDING.yml` was removed. Leaving it in place would put a
sponsor button on this fork soliciting on the original author's behalf, which is
not this repository's to display. Credit is given in the README and the LICENSE.

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
| `App/AppState.swift` | Fallback logic in `loadSystems()`, `loadFromSSH()`, SSH target management, and a `dataSource` guard on the three hub-only loaders. |
| `App/SettingsView.swift` | One new tab case. |
| `Menu/MenuBuilder.swift` | A banner when SSH is carrying the app; the empty state now accounts for SSH-only setups. |

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

## Requirements

Every target needs an agent supporting the `stats` subcommand — see
[`../agent-patch/`](../agent-patch/). Stock Beszel agents do not have it.

## Building without Xcode

`build-spm.sh` compiles with the Command Line Tools and assembles the `.app`
bundle by hand, because upstream's `xcodebuild` path needs a full Xcode install.
The bundle is ad-hoc signed: enough for a stable identity across rebuilds, not a
Developer ID signature, so Gatekeeper will still prompt on first launch.

The one thing it gives up is the compiled asset catalog — `actool` ships with
Xcode — so the icon is built with `iconutil` instead. For a menu bar app that
icon is rarely seen.
