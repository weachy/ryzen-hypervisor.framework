#!/bin/bash
#
# Timeout-protected bind-mount smoke test for Docker Desktop on RyzenHV.
#
#   ./scripts/rhv-smoke-bind-mount.sh            # 45 s timeout per docker run
#   ./scripts/rhv-smoke-bind-mount.sh --timeout 90
#   ./scripts/rhv-smoke-bind-mount.sh --image busybox
#
# Docker Desktop 4.97.0 hangs forever on host mounts instead of failing, so a
# plain `docker run -v` is not a usable check. This script wraps every docker
# command in a watchdog and prints the log locations on failure.
set -u

TIMEOUT=45
IMAGE=alpine
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) shift; TIMEOUT="${1:-45}" ;;
        --image)   shift; IMAGE="${1:-alpine}" ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# macOS has neither timeout nor gtimeout; use a watchdog that kills the child tree.
run_timeout() {
    local secs="$1"; shift
    ( "$@" ) &
    local pid=$!
    ( sleep "$secs"
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true ) &
    local wd=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
    [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ] && rc=124
    return "$rc"
}

T="$(mktemp -d "${TMPDIR:-/tmp}/rhv-bind-smoke.XXXXXX")" || exit 1
cleanup() { rm -f "$T/host.txt" "$T/from-container.txt" 2>/dev/null; rmdir "$T" 2>/dev/null || true; }
trap cleanup EXIT
printf 'rhv-smoke\n' > "$T/host.txt"

echo "checking daemon..."
run_timeout 10 docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || {
    echo "FAIL: Docker daemon is not answering. Start Docker Desktop first (or ./rhv docker-desktop)." >&2
    exit 1
}

echo "checking a container WITHOUT a host mount (control)..."
run_timeout "$TIMEOUT" docker run --rm "$IMAGE" echo CONTROL_OK >/dev/null 2>&1 || {
    echo "FAIL: even a plain container does not start; this is not a file-sharing problem." >&2
    exit 1
}

echo "checking a host bind mount (${TIMEOUT}s timeout)..."
OUT="$(run_timeout "$TIMEOUT" docker run --rm -v "$T:/work" -w /work "$IMAGE" \
        sh -c 'cat host.txt && echo container-ok > from-container.txt && echo MOUNT_OK' 2>&1)"
RC=$?
if [ "$RC" -eq 124 ]; then
    cat >&2 <<EOF
FAIL: bind mount timed out after ${TIMEOUT}s with no output — the gRPC-FUSE I/O hang.
  On RyzenHV this is a known issue on Docker Desktop 4.97.0 (build 244584):
  use the recommended Docker Desktop 4.43.2 (build 199162) via './rhv docker-desktop get'.
  Also check settings-store.json (>= 4.35.0) or settings.json (< 4.35.0) to ensure
  Virtualization Framework is disabled and gRPC-FUSE is enabled.
  Logs: ~/.ryzenhv/hyperkit.log and
        ~/Library/Containers/com.docker.docker/Data/log/host/com.docker.backend.real.log
  Inside the VM: docker run --rm --privileged --pid=host alpine \\
      sh -c 'ls /proc/1/root/host_mnt'   (hangs when FUSE I/O is dead)
EOF
    exit 1
fi
if [ "$RC" -ne 0 ]; then
    echo "FAIL: bind mount returned $RC: $OUT" >&2
    echo "  'mounts denied' means the host path is not in Settings > Resources > File sharing." >&2
    exit 1
fi
[ -f "$T/from-container.txt" ] || {
    echo "FAIL: the container's write did not reach the host; file sharing is broken." >&2
    exit 1
}
printf '%s\n' "$OUT"
echo "PASS: bind mount reads and writes in both directions."
