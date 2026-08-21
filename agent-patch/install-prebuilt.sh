#!/bin/bash

# Install one of the prebuilt BeszelBar snapshot agents without requiring Go.
# The operation is explicit, tests the new binary before replacement, and keeps
# the first previous binary as a rollback copy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREBUILT_DIR="${SCRIPT_DIR}/prebuilt"

usage() {
    cat <<'USAGE'
Kullanım:
  ./agent-patch/install-prebuilt.sh linux-amd64 kullanici@sunucu [ssh-anahtari]
  ./agent-patch/install-prebuilt.sh linux-arm64 kullanici@sunucu [ssh-anahtari]
  ./agent-patch/install-prebuilt.sh windows-amd64 kullanici@sunucu [ssh-anahtari]
  ./agent-patch/install-prebuilt.sh darwin-arm64 local

Örnek:
  ./agent-patch/install-prebuilt.sh linux-amd64 root@sunucu.example ~/.ssh/id_ed25519
USAGE
}

[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }

PLATFORM="$1"
TARGET="$2"
KEY_PATH="${3:-}"
BINARY_NAME="beszel-agent-${PLATFORM}"
[[ "$PLATFORM" == "windows-amd64" ]] && BINARY_NAME="${BINARY_NAME}.exe"
BINARY_PATH="${PREBUILT_DIR}/${BINARY_NAME}"
CHECKSUMS="${PREBUILT_DIR}/SHA256SUMS"

case "$PLATFORM" in
    linux-amd64|linux-arm64|windows-amd64|darwin-arm64) ;;
    *) echo "Desteklenmeyen platform: ${PLATFORM}" >&2; usage; exit 2 ;;
esac

[[ -f "$BINARY_PATH" ]] || {
    echo "Hazır agent bulunamadı: ${BINARY_PATH}" >&2
    exit 1
}

EXPECTED="$(awk -v name="$BINARY_NAME" '$2 == name { print $1 }' "$CHECKSUMS")"
ACTUAL="$(shasum -a 256 "$BINARY_PATH" | awk '{ print $1 }')"
[[ -n "$EXPECTED" && "$ACTUAL" == "$EXPECTED" ]] || {
    echo "Agent doğrulaması başarısız: ${BINARY_NAME}" >&2
    exit 1
}

if [[ "$PLATFORM" == "darwin-arm64" ]]; then
    [[ "$TARGET" == "local" ]] || {
        echo "darwin-arm64 hedefi 'local' olmalıdır." >&2
        exit 2
    }
    DEST_DIR="${HOME}/.local/bin"
    DEST="${DEST_DIR}/beszel-agent-stats"
    mkdir -p "$DEST_DIR"
    if [[ -e "$DEST" && ! -e "${DEST}.pre-balloon" ]]; then
        cp -p "$DEST" "${DEST}.pre-balloon"
    fi
    install -m 755 "$BINARY_PATH" "$DEST"
    "$DEST" stats 0s >/dev/null
    echo "Kuruldu: ${DEST}"
    exit 0
fi

[[ "$TARGET" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]] || {
    echo "Hedef 'kullanici@sunucu' biçiminde olmalıdır." >&2
    exit 2
}

SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=20)
if [[ -n "$KEY_PATH" ]]; then
    if [[ "$KEY_PATH" == ~/* ]]; then
        KEY_PATH="${HOME}/${KEY_PATH#~/}"
    fi
    SSH_OPTIONS+=(-o IdentitiesOnly=yes -i "$KEY_PATH")
fi

if [[ "$PLATFORM" == "windows-amd64" ]]; then
    REMOTE_DIR="C:/beszel"
    REMOTE_BINARY="${REMOTE_DIR}/beszel-agent-stats.new.exe"
    REMOTE_INSTALLER="${REMOTE_DIR}/install-beszelbar-agent.ps1"

    ssh "${SSH_OPTIONS[@]}" "$TARGET" \
        'powershell -NoProfile -Command "New-Item -ItemType Directory -Force C:\beszel | Out-Null"'
    scp "${SSH_OPTIONS[@]}" "$BINARY_PATH" "${TARGET}:${REMOTE_BINARY}"
    scp "${SSH_OPTIONS[@]}" "${SCRIPT_DIR}/install-windows-agent.ps1" \
        "${TARGET}:${REMOTE_INSTALLER}"
    ssh "${SSH_OPTIONS[@]}" "$TARGET" \
        "powershell -NoProfile -ExecutionPolicy Bypass -File ${REMOTE_INSTALLER}"
    exit 0
fi

REMOTE_TEMP="/tmp/beszel-agent-stats.$$.new"
REMOTE_LIVE="/opt/beszel-agent/beszel-agent-stats"
REMOTE_BACKUP="${REMOTE_LIVE}.pre-balloon"

scp "${SSH_OPTIONS[@]}" "$BINARY_PATH" "${TARGET}:${REMOTE_TEMP}"
ssh "${SSH_OPTIONS[@]}" "$TARGET" \
    "set -eu; chmod 755 '${REMOTE_TEMP}'; '${REMOTE_TEMP}' stats 0s >/dev/null; \
     if [ -e '${REMOTE_LIVE}' ] && [ ! -e '${REMOTE_BACKUP}' ]; then \
       cp -p '${REMOTE_LIVE}' '${REMOTE_BACKUP}'; \
     fi; \
     install -m 755 '${REMOTE_TEMP}' '${REMOTE_LIVE}'; \
     rm -f '${REMOTE_TEMP}'; \
     '${REMOTE_LIVE}' stats 0s >/dev/null"

echo "Kuruldu: ${TARGET}:${REMOTE_LIVE}"
