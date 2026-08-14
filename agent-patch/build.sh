#!/bin/bash
#
# Fetch upstream Beszel, apply the stats patch, and cross-compile the agent.
#
# The patch is carried here rather than a vendored copy of Beszel because the
# change is 35 lines against a large upstream. A fork of the whole repository
# would bury a small edit in a mountain of somebody else's code and go stale the
# moment upstream moves.

set -euo pipefail

cd "$(dirname "$0")"

UPSTREAM_TAG="${UPSTREAM_TAG:-v0.18.7}"
SRC_DIR="beszel"
OUT_DIR="../bin"

if ! command -v go > /dev/null; then
    echo "Go toolchain not found. Install it first (brew install go)." >&2
    exit 1
fi

if [[ ! -d "$SRC_DIR" ]]; then
    echo "==> Cloning upstream at ${UPSTREAM_TAG}"
    git clone --depth 1 --branch "$UPSTREAM_TAG" https://github.com/henrygd/beszel.git "$SRC_DIR"
else
    echo "==> Using existing checkout in ${SRC_DIR}"
fi

cd "$SRC_DIR"

if git apply --check ../0001-add-stats-subcommand.patch 2>/dev/null; then
    echo "==> Applying stats patch"
    git apply ../0001-add-stats-subcommand.patch
else
    echo "==> Patch already applied (or does not fit this tag)"
fi

# Two embedded blobs upstream fetches during release builds. Without them the
# Windows target does not compile, because go:embed insists the paths exist.
echo "==> Preparing Windows embeds"
go generate -run fetchsmartctl ./agent

LHM_DIR="agent/lhm/bin/Release/net48"
if [[ ! -d "$LHM_DIR" ]]; then
    mkdir -p "$LHM_DIR"
    cat > "${LHM_DIR}/PLACEHOLDER.md" <<'NOTE'
Stands in for the LibreHardwareMonitor build output that upstream produces with
`dotnet build`. Building it needs the .NET SDK, and the component is opt-in
(LHM=true) and off by default, so this placeholder satisfies go:embed instead.

The cost is that temperature sensors do not work on Windows in binaries built
this way. Everything the stats subcommand reports — cpu, memory, disk, swap,
load — is unaffected.
NOTE
    echo "    placeholder written (Windows temperature sensors will be unavailable)"
fi

mkdir -p "$OUT_DIR"

echo "==> Building"
for spec in "linux amd64 beszel-agent-linux-amd64" \
            "linux arm64 beszel-agent-linux-arm64" \
            "windows amd64 beszel-agent-windows-amd64.exe" \
            "darwin arm64 beszel-agent-darwin-arm64"; do
    set -- $spec
    GOOS="$1" GOARCH="$2" CGO_ENABLED=0 go build -ldflags "-s -w" \
        -o "${OUT_DIR}/$3" ./internal/cmd/agent
    echo "    $3"
done

echo
echo "Binaries in $(cd "$OUT_DIR" && pwd)"
echo "Verify with: <binary> stats | head"
