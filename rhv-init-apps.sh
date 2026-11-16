#!/bin/bash
#
# rhv-init-apps.sh — Standalone application-layer initializer for RyzenHV (shim mode)
#
# Scope:
#   - OpenCore / EFI already has RyzenHV.kext installed, with boot-args containing:
#       rhv_enable_svm=1 rhv_allow_users=1 amfi_get_out_of_my_way=0x1
#   - Pure shim mode (boot-args must NOT contain rhv_hv=1).
#   - Tested on macOS 15.8.2 / Ryzen 7 7730U / RyzenHV 0.7.8.
#
# Features (standalone):
#   1. Zero dependency on libexec/*.sh or ./rhv in the release bundle.
#   2. Built-in Docker Desktop HyperKit & backend shim patching (recommended: 4.43.2 / build 199162).
#   3. Cross-version Docker Desktop settings support:
#      - < 4.35.0 (build 172550): modifies settings.json (camelCase keys)
#      - >= 4.35.0 (build 172550): modifies settings-store.json (PascalCase keys)
#      Configures HyperKit + gRPC-FUSE + disables automatic updates.
#   4. Built-in Parallels Desktop shim installation & management (private farm copy + prl_vm_app wrapper).
#   5. Auto-detects GPU vendor for Parallels 3D acceleration (highest on AMD Vega iGPU / AMD dGPU, off on NVIDIA NVMTL).
#   6. Built-in system diagnostics (replaces ./rhv doctor without version false positives or QEMU checks).
#   7. Optional startup verification & bidirectional bind-mount smoke test (--smoke-test / --verify).
#   8. Supports --undo to restore original Docker Desktop and Parallels Desktop files.
#
# Usage:
#   ./rhv-init-apps.sh                    # Initialize (skips smoke test by default)
#   ./rhv-init-apps.sh --smoke-test       # Initialize and run Docker & bind-mount smoke test (alias: --verify)
#   ./rhv-init-apps.sh --smoke-only       # Run only the smoke test without re-initializing
#   ./rhv-init-apps.sh --check            # Read-only diagnostics (recommended first)
#   ./rhv-init-apps.sh --yes              # Skip interactive confirmation prompts
#   ./rhv-init-apps.sh --install-docker   # Download and install Docker Desktop 4.43.2 (199162) if missing or different
#   ./rhv-init-apps.sh --docker-dmg /path/Docker.dmg --install-docker
#   ./rhv-init-apps.sh --stop-vms --stop-docker    # Allow stopping running VMs / Docker automatically
#   ./rhv-init-apps.sh --keep-3d-off      # Do not enable 3D acceleration (keep upstream default)
#   ./rhv-init-apps.sh --verify-pd-boot   # Cold-boot a Windows VM once to verify 3D acceleration
#   ./rhv-init-apps.sh --rhv-dir /path/to/ryzenhv-0.7.8 # Specify RyzenHV release bundle directory
#   ./rhv-init-apps.sh --skip-pd | --skip-docker
#   ./rhv-init-apps.sh --undo             # Restore original Docker Desktop and Parallels Desktop files
#
# Note: Installing the Parallels wrapper requires sudo and will prompt for your password in the terminal.
#       Run in an interactive TTY (unless passwordless sudo is configured).
#
set -u
set -o pipefail

VERSION="2.1.0-standalone"
DOCKER_BUILD_WANT=199162
DOCKER_VERSION_WANT="4.43.2"
DOCKER_DMG_URL="https://desktop.docker.com/mac/main/amd64/199162/Docker.dmg"
DOCKER_SETTINGS_SPLIT_VERSION="4.35.0"
DOCKER_SETTINGS_SPLIT_BUILD=172550
PD_BUILD_WANT=57613
SETTINGS_DIR="$HOME/Library/Group Containers/group.com.docker"
SETTINGS_JSON="$SETTINGS_DIR/settings.json"              # < 4.35.0 (build 172550) (camelCase keys)
SETTINGS_STORE_JSON="$SETTINGS_DIR/settings-store.json"  # >= 4.35.0 (build 172550) (PascalCase keys)
PD_DOMAIN="com.parallels.Parallels Desktop"
LOG="$HOME/.ryzenhv/init-apps.log"
STAMP="$(date +%Y%m%d-%H%M%S)"

RHV_DIR=""; DOCKER_DMG=""; INSTALL_DOCKER=0; KEEP_3D_OFF=0
SKIP_PD=0; SKIP_DOCKER=0; RUN_VERIFY=0; SMOKE_ONLY=0; ASSUME_YES=0; CHECK_ONLY=0
STOP_VMS=0; STOP_DOCKER=0; VERIFY_PD_BOOT=0; SKIP_DOCTOR=0
FORCE_KEEP_DOCKER=0; CHECK_FAILS=0; DO_UNDO=0

if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_N=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_N=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_N"; }
ok()   { printf '  %s[OK]%s   %b\n' "$C_G" "$C_N" "$*"; }
warn() { printf '  %s[WARN]%s %b\n' "$C_Y" "$C_N" "$*"; }
bad()  { printf '  %s[FAIL]%s %b\n' "$C_R" "$C_N" "$*"; }
die()  { printf '\n%sError:%b%s\n' "$C_R" " $*" "$C_N"; { printf '[%s] ERROR: %b\n' "$(date '+%F %T')" "$*" >> "$LOG"; } 2>/dev/null || true; exit 1; }
fatal_state() { if [ "$CHECK_ONLY" -eq 1 ]; then warn "$*"; CHECK_FAILS=$((CHECK_FAILS+1)); else die "$*"; fi; }
log()  { mkdir -p "$(dirname "$LOG")" 2>/dev/null; { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; } 2>/dev/null || true; }

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || die "Interactive confirmation requires a TTY; pass --yes or run in a terminal."
  printf '  %s [y/N] ' "$1"; read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Watchdog timeout wrapper (macOS has no timeout/gtimeout)
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

is_script() { [ -e "$1" ] && [ "$(head -c 2 "$1" 2>/dev/null)" = '#!' ]; }

# Capture output before matching to avoid SIGPIPE under pipefail
is_docker_signed() {
  local out; out="$(codesign -dv "$1" 2>&1)"
  grep -q "TeamIdentifier=9BNSXJN65R" <<<"$out"
}

# Compare dotted version numbers: returns 0 if $1 >= $2, else 1
ver_ge() {
  local a b i va vb
  IFS='.' read -ra a <<< "${1%%[^0-9.]*}"
  IFS='.' read -ra b <<< "${2%%[^0-9.]*}"
  for ((i=0; i<3; i++)); do
    va="${a[i]:-0}"; vb="${b[i]:-0}"
    va="${va:-0}"; vb="${vb:-0}"
    if [ "$va" -gt "$vb" ] 2>/dev/null; then return 0; fi
    if [ "$va" -lt "$vb" ] 2>/dev/null; then return 1; fi
  done
  return 0
}

# Returns 0 if Docker Desktop >= 4.35.0 (build 172550), which uses settings-store.json
docker_uses_settings_store() {
  local dv="${1:-}" db="${2:-}"
  if [ -n "$dv" ] && [ "$dv" != "?" ] && [[ "$dv" =~ ^[0-9]+(\.[0-9]+)* ]]; then
    ver_ge "$dv" "$DOCKER_SETTINGS_SPLIT_VERSION"
    return $?
  fi
  if [ -n "$db" ] && [ "$db" != "?" ] && [[ "$db" =~ ^[0-9]+$ ]]; then
    [ "$db" -ge "$DOCKER_SETTINGS_SPLIT_BUILD" ]
    return $?
  fi
  return 0
}

# Detect GPU vendor for Parallels 3D acceleration (nvidia -> off, amd -> highest)
detect_gpu_vendor() {
  local sp ks
  sp="$(system_profiler SPDisplaysDataType 2>/dev/null || true)"
  if grep -qiE "NVIDIA|0x10de" <<<"$sp"; then echo "nvidia"; return 0; fi
  if grep -qiE "AMD|Radeon|0x1002" <<<"$sp"; then echo "amd"; return 0; fi
  ks="$(kextstat 2>/dev/null || true)"
  if grep -qiE "NVMTL|NVIDIA|GeForce" <<<"$ks"; then echo "nvidia"; return 0; fi
  if grep -qiE "AMDRadeon|AMDFramebuffer|NootedRed" <<<"$ks"; then echo "amd"; return 0; fi
  echo "unknown"
}

# JSON helpers: prefer python3, fall back to macOS plutil
PY=""
if [ -x /usr/bin/python3 ]; then PY=/usr/bin/python3
elif command -v python3 >/dev/null 2>&1; then PY="$(command -v python3)"; fi

json_set() {
  local f="$1" k="$2" t="$3" v="$4"
  if [ -n "$PY" ]; then
    "$PY" - "$f" "$k" "$t" "$v" <<'PYEOF' || return 1
import json, os, sys
f, k, t, v = sys.argv[1:5]
d = {}
if os.path.exists(f) and os.path.getsize(f) > 0:
    try:
        with open(f, "r") as fh:
            d = json.load(fh)
    except Exception:
        d = {}
parse = {"bool": lambda x: x.lower() in ("1", "true", "yes", "on"),
         "int": int, "str": lambda x: x, "json": json.loads}
d[k] = parse[t](v)
with open(f, "w") as fh:
    json.dump(d, fh, indent=2)
PYEOF
  else
    local bv
    case "$t" in
      bool) case "$v" in true|1|yes|YES) bv=YES ;; *) bv=NO ;; esac
            plutil -replace "$k" -bool "$bv" "$f" ;;
      int)  plutil -replace "$k" -integer "$v" "$f" ;;
      str)  plutil -replace "$k" -string "$v" "$f" ;;
      json) plutil -replace "$k" -json "$v" "$f" ;;
    esac || return 1
  fi
}

json_get() {
  [ -f "$1" ] || { printf ''; return 0; }
  if [ -n "$PY" ]; then
    "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null
  else
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
  fi
}

json_valid() {
  if [ -n "$PY" ]; then "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
  else plutil -convert xml1 -o /dev/null "$1" >/dev/null 2>&1; fi
}

backup_file() { [ -f "$1" ] && cp -p "$1" "$1.bak-rhv-init-$STAMP" && ok "Backed up $(basename "$1")"; return 0; }

# ---------------------------------------------------------------- Built-in standalone shim helpers

# 1. Docker Desktop shim status
docker_shim_status() {
  local app="/Applications/Docker.app"
  local wrap="$app/Contents/Resources/bin/com.docker.hyperkit"
  local back="$app/Contents/MacOS/com.docker.backend"
  [ -d "$app" ] || { echo "not installed"; return 2; }
  if is_script "$wrap" && is_script "$back"; then
    echo "installed (HyperKit and backend wrapped)"
    return 0
  elif is_script "$wrap" || is_script "$back"; then
    echo "half installed (incomplete state)"
    return 1
  else
    echo "not installed (original binaries)"
    return 2
  fi
}

# 2. Docker Desktop shim install (standalone, no dependency on libexec/docker-desktop-shim.sh)
docker_shim_install() {
  local shim_src="$1"
  local app="/Applications/Docker.app"
  local bin="$app/Contents/Resources/bin"
  local orig="$bin/com.docker.hyperkit.orig"
  local real="$bin/com.docker.hyperkit.real"
  local wrap="$bin/com.docker.hyperkit"
  local back="$app/Contents/MacOS/com.docker.backend"
  local back_real="$back.real"
  local libdir="$HOME/.ryzenhv/lib"

  [ -d "$app" ] || die "Docker Desktop is not installed at $app"
  pgrep -f "$back" >/dev/null 2>&1 && die "Please quit Docker Desktop first (menu bar whale > Quit)"
  [ -f "$shim_src" ] || die "libryzenhv.dylib not found: $shim_src"

  mkdir -p "$libdir"
  cp -p "$shim_src" "$libdir/libryzenhv.dylib" || die "Failed to copy libryzenhv.dylib to $libdir"

  # HyperKit wrapper
  local src
  if is_script "$wrap"; then src="$orig"; else src="$wrap"; fi
  [ -e "$orig" ] || cp -p "$src" "$orig" || die "Failed to back up HyperKit"
  is_docker_signed "$orig" || die "$orig is not Docker's signed binary (if left over from a failed run, quit Docker, remove the .orig file, and retry)"
  cp -p "$orig" "$real" || die "Failed to prepare $real"
  chmod u+w "$real"

  local ent
  ent="$(mktemp -t rhv-ent.XXXXXX)"
  cat > "$ent" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
EOF
  codesign --force --sign - --entitlements "$ent" "$real" >/dev/null 2>&1 || die "Failed to ad-hoc sign $real with hypervisor entitlement"
  rm -f "$ent" 2>/dev/null || true

  cat > "$wrap" <<WRAP
#!/bin/bash
# RyzenHV wrapper, generated by rhv-init-apps.sh
export DYLD_INSERT_LIBRARIES="$libdir/libryzenhv.dylib"
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-F" ] && [ -f "\$a" ]; then
        pid="\$(cat "\$a" 2>/dev/null)"
        if [ -z "\$pid" ] || ! ps -p "\$pid" >/dev/null 2>&1; then rm -f "\$a" 2>/dev/null || true; fi
    fi
    prev="\$a"
done
exec "\$(dirname "\$0")/com.docker.hyperkit.real" "\$@" 2> >(tee -a "$HOME/.ryzenhv/hyperkit.log" >&2)
WRAP
  chmod 755 "$wrap"

  # Backend wrapper
  if ! is_script "$back"; then
    mv "$back" "$back_real" || die "Failed to rename backend binary"
  fi
  cat > "$back" <<WRAP
#!/bin/bash
# RyzenHV wrapper, generated by rhv-init-apps.sh
export DYLD_INSERT_LIBRARIES="$libdir/libryzenhv.dylib"
exec "\$(dirname "\$0")/com.docker.backend.real" "\$@"
WRAP
  chmod 755 "$back"
}

# 3. Docker Desktop shim uninstall
docker_shim_uninstall() {
  local app="/Applications/Docker.app"
  local bin="$app/Contents/Resources/bin"
  local orig="$bin/com.docker.hyperkit.orig"
  local real="$bin/com.docker.hyperkit.real"
  local wrap="$bin/com.docker.hyperkit"
  local back="$app/Contents/MacOS/com.docker.backend"
  local back_real="$back.real"

  pgrep -f "$back" >/dev/null 2>&1 && die "Please quit Docker Desktop first"
  if [ -e "$orig" ]; then
    rm -f "$wrap" "$real" 2>/dev/null || true
    mv "$orig" "$wrap"
  fi
  if [ -e "$back_real" ]; then
    rm -f "$back" 2>/dev/null || true
    mv "$back_real" "$back"
  fi
}

# 4. Parallels Desktop shim status
parallels_shim_status() {
  local app="/Applications/Parallels Desktop.app"
  local dir="$app/Contents/MacOS/Parallels VM.app/Contents/MacOS"
  local wrapper="$dir/prl_vm_app"
  local farm="$HOME/.ryzenhv/prl/Parallels Desktop.app"
  local farm_bin="$farm/Contents/MacOS/Parallels VM.app/Contents/MacOS/prl_vm_app"
  [ -d "$app" ] || { echo "not installed"; return 2; }
  if is_script "$wrapper"; then
    local p="present"
    [ -x "$farm_bin" ] || p="missing"
    local m="unknown"
    [ -f "$HOME/.ryzenhv/prl/MODE" ] && m="$(cat "$HOME/.ryzenhv/prl/MODE" 2>/dev/null || echo unknown)"
    echo "installed (wrapper installed, private copy: $p, mode: $m)"
    return 0
  else
    echo "not installed (original prl_vm_app in place)"
    return 2
  fi
}

# 5. Parallels Desktop shim prepare & install (standalone, no dependency on libexec/parallels-shim.sh)
parallels_shim_prepare() {
  local standin_lib="$1"
  local app="/Applications/Parallels Desktop.app"
  local dir="$app/Contents/MacOS/Parallels VM.app/Contents/MacOS"
  local wrapper="$dir/prl_vm_app"
  local real="$dir/prl_vm_app.real"
  local orig="$dir/prl_vm_app.orig"
  local farm="$HOME/.ryzenhv/prl/Parallels Desktop.app"
  local farm_bin="$farm/Contents/MacOS/Parallels VM.app/Contents/MacOS/prl_vm_app"

  [ -d "$app" ] || die "Parallels Desktop not found at $app"
  [ -f "$standin_lib" ] || die "Missing stand-in library: $standin_lib"

  local src_bin
  if [ -e "$orig" ]; then src_bin="$orig"
  elif [ -e "$wrapper" ] && ! is_script "$wrapper"; then src_bin="$wrapper"
  else src_bin="$real"; fi

  if [ ! -f "$src_bin" ] || is_script "$src_bin"; then
    die "$src_bin is not an original Parallels binary (leftover wrapper?). Restore original first."
  fi

  rm -f "$HOME/.ryzenhv/prl"/* 2>/dev/null || true
  trash "$HOME/.ryzenhv/prl" 2>/dev/null || true
  mkdir -p "$farm/Contents/Frameworks" "$farm/Contents/MacOS"

  for e in "$app/Contents"/*; do
    local n; n="$(basename "$e")"
    case "$n" in Frameworks|MacOS) ;; *) ln -s "$e" "$farm/Contents/$n" ;; esac
  done
  for e in "$app/Contents/Frameworks"/*; do
    local n; n="$(basename "$e")"
    [ "$n" = "libPrlXmlModel.1.dylib" ] || ln -s "$e" "$farm/Contents/Frameworks/$n"
  done
  for e in "$app/Contents/MacOS"/*; do
    local n; n="$(basename "$e")"
    [ "$n" = "Parallels VM.app" ] || ln -s "$e" "$farm/Contents/MacOS/$n"
  done

  cp -R "$dir/../.." "$farm/Contents/MacOS/Parallels VM.app" || die "Failed to copy Parallels VM.app"
  rm -f "$farm/Contents/MacOS/Parallels VM.app/Contents/MacOS/prl_vm_app.real" 2>/dev/null || true
  rm -f "$farm/Contents/MacOS/Parallels VM.app/Contents/MacOS/prl_vm_app.orig" 2>/dev/null || true
  cp -p "$src_bin" "$farm_bin" || die "Failed to copy prl_vm_app to private farm"

  cp -p "$app/Contents/Frameworks/libPrlXmlModel.1.dylib" "$farm/Contents/Frameworks/libPrlXmlModel.1.orig.dylib" || die "Failed to back up libPrlXmlModel.1.dylib"
  cp "$standin_lib" "$farm/Contents/Frameworks/libPrlXmlModel.1.dylib" || die "Failed to copy stand-in library"
  codesign --force --sign - "$farm/Contents/Frameworks/libPrlXmlModel.1.dylib" >/dev/null 2>&1 || die "Failed to sign stand-in library"
  echo shim > "$HOME/.ryzenhv/prl/MODE"
}

parallels_shim_install() {
  local app="/Applications/Parallels Desktop.app"
  local dir="$app/Contents/MacOS/Parallels VM.app/Contents/MacOS"
  local wrapper="$dir/prl_vm_app"
  local real="$dir/prl_vm_app.real"
  local orig="$dir/prl_vm_app.orig"
  local farm="$HOME/.ryzenhv/prl/Parallels Desktop.app"
  local farm_bin="$farm/Contents/MacOS/Parallels VM.app/Contents/MacOS/prl_vm_app"

  [ -x "$farm_bin" ] || die "Private farm copy is not ready; cannot install wrapper"
  [ -e "$wrapper" ] || die "Not found: $wrapper"

  sudo /bin/bash <<SUDO_EOF
set -e
if ! [ -e "$wrapper" ] || ! head -c 2 "$wrapper" | grep -q '#!'; then
    [ -e "$orig" ] && rm -f "$orig" 2>/dev/null || true
    cp -p "$wrapper" "$orig"
    mv "$wrapper" "$real"
fi
[ -e "$orig" ] || cp -p "$real" "$orig"
cp -p "$orig" "$real"
cat > "$wrapper" <<'WRAP'
#!/bin/bash
# RyzenHV wrapper, generated by rhv-init-apps.sh
# Starts the private copy of the VM app that has the Hypervisor.framework shim built in.
export RYZENHV_TRACE=\${RYZENHV_TRACE:-2} RYZENHV_TRACE_FILE=/tmp/rhv-prl-\$\$.trace
export RYZENHV_STATS=1 RYZENHV_STATS_FILE=/tmp/rhv-prl-\$\$.stats
if [ -x "$farm_bin" ]; then exec "$farm_bin" "\$@"; fi
exec "\$(dirname "\$0")/prl_vm_app.real" "\$@"
WRAP
chmod 755 "$wrapper"
chown root:wheel "$wrapper"
SUDO_EOF
}

# 6. Parallels Desktop shim uninstall
parallels_shim_uninstall() {
  local app="/Applications/Parallels Desktop.app"
  local dir="$app/Contents/MacOS/Parallels VM.app/Contents/MacOS"
  local wrapper="$dir/prl_vm_app"
  local real="$dir/prl_vm_app.real"
  local orig="$dir/prl_vm_app.orig"

  if [ -e "$orig" ]; then
    sudo /bin/bash <<SUDO_EOF
rm -f "$wrapper" "$real" 2>/dev/null || true
mv "$orig" "$wrapper"
SUDO_EOF
  fi
  rm -f "$HOME/.ryzenhv/prl"/* 2>/dev/null || true
  trash "$HOME/.ryzenhv/prl" 2>/dev/null || true
}

# 7. Startup verification & bind-mount smoke test
run_smoke_test() {
  step "Startup verification & bind-mount smoke test (with timeout protection)"
  if [ -x /usr/local/bin/docker-up ]; then /usr/local/bin/docker-up >/dev/null 2>&1 || open -a Docker
  else open -a Docker; fi
  local ready=0
  for i in $(seq 1 50); do
    if run_timeout 6 docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then ready=1; break; fi
    sleep 3
  done
  [ "$ready" -eq 1 ] || die "Docker daemon not ready within 150s.\n  Check:\n  1) tail -40 ~/.ryzenhv/hyperkit.log\n  2) tail -60 ~/Library/Containers/com.docker.docker/Data/log/host/com.docker.backend.real.log\n  3) Verify Virtualization Framework is disabled in settings.json / settings-store.json"
  ok "Docker daemon ready: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"

  local t
  t="$(mktemp -d /private/tmp/rhv-init-verify.XXXXXX)"
  printf 'rhv-init-ok\n' > "$t/host.txt"
  say "  Running host bind-mount smoke test (45s timeout)..."
  local out vrc
  out="$(run_timeout 45 docker run --rm -v "$t:/work" -w /work alpine sh -c 'cat host.txt && echo container > from-container.txt && echo MOUNT_OK' 2>&1)"; vrc=$?
  if [ "$vrc" -eq 124 ]; then
    trash "$t" 2>/dev/null || true
    die "Bind mount timed out! This is a known gRPC-FUSE I/O hang symptom.\n  Recommended: Docker Desktop ${DOCKER_VERSION_WANT} (${DOCKER_BUILD_WANT}) (supports HyperKit + gRPC-FUSE + Host networking);\n  Also verify gRPC-FUSE is enabled and Virtualization Framework is disabled."
  fi
  [ "$vrc" -eq 0 ] || { trash "$t" 2>/dev/null || true; die "Bind mount test failed (rc=${vrc}): $out" ; }
  [ -f "$t/from-container.txt" ] || { trash "$t" 2>/dev/null || true; die "Container write did not appear on host; file sharing is not working."; }
  printf '%s\n' "$out" | sed 's/^/    /'
  trash "$t" 2>/dev/null || true
  ok "Bidirectional bind-mount smoke test passed!"

  if [ "$SKIP_PD" -eq 0 ] && [ "$KEEP_3D_OFF" -eq 0 ]; then
    ok "Parallels 3D acceleration is set to highest"
  fi
  if [ "$VERIFY_PD_BOOT" -eq 1 ] && [ "$SKIP_PD" -eq 0 ]; then
    local u
    u="$(prlctl list -a -o uuid,status 2>/dev/null | awk 'NR>1 && $2=="stopped" {print $1; exit}')"
    if [ -n "$u" ]; then
      say "  Cold-booting VM $u to verify 3D acceleration (up to 90s)..."
      prlctl start "$u" >/dev/null 2>&1 || die "Failed to start VM: prlctl start \"$u\""
      local alive=1
      for i in $(seq 1 15); do
        sleep 4
        pgrep -f prl_vm_app >/dev/null 2>&1 || { alive=0; break; }
      done
      run_timeout 90 prlctl stop "$u" >/dev/null 2>&1 || warn "VM did not stop gracefully; please run prlctl stop manually"
      [ "$alive" -eq 1 ] && ok "prl_vm_app ran for 60s with 3D acceleration enabled without crashing" \
        || die "prl_vm_app exited after enabling 3D. Check /Library/Logs/DiagnosticReports/prl_vm_app-*.ips."
    fi
  fi
}

# ---------------------------------------------------------------- Argument parsing
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --install-docker) INSTALL_DOCKER=1 ;;
    --docker-dmg) shift; DOCKER_DMG="${1:-}"; [ -n "$DOCKER_DMG" ] || die "--docker-dmg requires a path" ;;
    --rhv-dir) shift; RHV_DIR="${1:-}"; [ -n "$RHV_DIR" ] || die "--rhv-dir requires a directory" ;;
    --keep-3d-off) KEEP_3D_OFF=1 ;;
    --skip-pd) SKIP_PD=1 ;;
    --skip-docker) SKIP_DOCKER=1 ;;
    --verify|--smoke-test) RUN_VERIFY=1 ;;
    --smoke-only|--test-only|--verify-only) SMOKE_ONLY=1; RUN_VERIFY=1 ;;
    --no-verify) RUN_VERIFY=0 ;;
    --stop-vms) STOP_VMS=1 ;;
    --stop-docker) STOP_DOCKER=1 ;;
    --verify-pd-boot) VERIFY_PD_BOOT=1 ;;
    --skip-doctor) SKIP_DOCTOR=1 ;;
    --force-keep-docker) FORCE_KEEP_DOCKER=1 ;;
    --undo) DO_UNDO=1 ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1 (run with --help for usage)" ;;
  esac
  shift
done

say "$C_B rhv-init-apps $VERSION  |  RyzenHV Standalone App Initializer  |  $(date '+%F %T')$C_N"
[ "$CHECK_ONLY" -eq 1 ] && say "$C_Y[Read-only diagnostic mode --check: no files will be modified]$C_N"
log "start check_only=$CHECK_ONLY do_undo=$DO_UNDO smoke_only=$SMOKE_ONLY run_verify=$RUN_VERIFY"

# ---------------------------------------------------------------- 0. Undo mode
if [ "$DO_UNDO" -eq 1 ]; then
  step "Restore original files (--undo)"
  confirm "Restore original Docker Desktop and Parallels Desktop files?" || exit 0
  if [ "$SKIP_DOCKER" -eq 0 ] && [ -d /Applications/Docker.app ]; then
    docker_shim_uninstall
    ok "Docker Desktop original files restored"
  fi
  if [ "$SKIP_PD" -eq 0 ] && [ -d "/Applications/Parallels Desktop.app" ]; then
    parallels_shim_uninstall
    ok "Parallels Desktop original files restored"
  fi
  ok "Restore completed"
  exit 0
fi

# ---------------------------------------------------------------- 0. Smoke-only mode
if [ "$SMOKE_ONLY" -eq 1 ]; then
  step "Run smoke test only (--smoke-only)"
  [ -d /Applications/Docker.app ] || die "Docker Desktop is not installed at /Applications/Docker.app"
  run_smoke_test
  ok "Smoke test completed"
  exit 0
fi

# ---------------------------------------------------------------- 1. Environment & dependency checks
step "1/9  Environment & dependency checks"

[ "$(uname -s)" = "Darwin" ] || die "This script only runs on macOS (current: $(uname -s))"
[ "$(uname -m)" = "x86_64" ] || die "This script only applies to Intel/x86_64 Macs (current: $(uname -m)); Apple Silicon does not need RyzenHV."
ok "macOS $(sw_vers -productVersion 2>/dev/null) / x86_64"

CPU_VENDOR="$(sysctl -n machdep.cpu.vendor 2>/dev/null || echo '')"
[ "$CPU_VENDOR" = "AuthenticAMD" ] && ok "CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null)" || warn "CPU vendor is $CPU_VENDOR (RyzenHV is designed for AMD CPUs)"

# Locate RyzenHV release bundle (for bin/rhv-info and dylibs)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$RHV_DIR" ]; then
  for c in \
    "$PWD" \
    "$SCRIPT_DIR/.." \
    "$SCRIPT_DIR/../ryzenhv-"* \
    "$PWD"/ryzenhv-* \
    "$HOME"/Downloads/ryzenhv-* \
    "$HOME"/ryzenhv-* \
    /opt/ryzenhv-* \
    "$SCRIPT_DIR/../RyzenHV.app/Contents/Resources/bundle/ryzenhv-"* \
    "/Applications/RyzenHV.app/Contents/Resources/bundle/ryzenhv-"*; do
    if [ -d "$c" ] && [ -x "$c/bin/rhv-info" ] && [ -f "$c/lib/libryzenhv.dylib" ]; then
      RHV_DIR="$c"; break
    fi
  done
fi
[ -n "$RHV_DIR" ] && [ -d "$RHV_DIR" ] || die "RyzenHV release bundle not found. Pass --rhv-dir /path/to/ryzenhv-* (must contain bin/rhv-info and lib/libryzenhv.dylib)."
RHV_DIR="$(cd "$RHV_DIR" && pwd)"
BVER="$(sed -n 's/^version=//p' "$RHV_DIR/VERSION" 2>/dev/null | head -1)"
BABI="$(sed -n 's/^abi=//p' "$RHV_DIR/VERSION" 2>/dev/null | head -1)"
ok "RyzenHV bundle: $RHV_DIR (version ${BVER:-unknown}, ABI ${BABI:-unknown})"

RHV_INFO="$RHV_DIR/bin/rhv-info"
RHV_SHIM_LIB="$RHV_DIR/lib/libryzenhv.dylib"
RHV_PRL_LIB="$RHV_DIR/lib/libPrlXmlModel.1.dylib"

[ -x "$RHV_INFO" ] || die "Bundle is missing executable bin/rhv-info"
[ -f "$RHV_SHIM_LIB" ] || die "Bundle is missing lib/libryzenhv.dylib"
ok "Bundle core binaries and dylibs verified (standalone mode, no libexec/*.sh needed)"

# boot-args check
ARGS="$(nvram boot-args 2>/dev/null | sed 's/^boot-args[[:space:]]*//')"
for a in rhv_enable_svm=1 rhv_allow_users=1 amfi_get_out_of_my_way=0x1; do
  case " $ARGS " in *" $a "*) ;; *) die "boot-args is missing ${a}. Add it to OpenCore config.plist / NVRAM and reboot." ;; esac
done
case " $ARGS " in
  *" rhv_hv=1 "*) die "Detected rhv_hv=1 (native mode). This script is designed for pure shim mode.\n  Remove rhv_hv=1 from boot-args and reboot to use shim mode." ;;
esac
ok "boot-args verified (pure shim mode)"

# kern.hv_support check
[ "$(sysctl -n kern.hv_support 2>/dev/null)" = "0" ] && ok "kern.hv_support=0 (spoofed to 1 inside shimmed processes)" || warn "kern.hv_support is non-zero; ensure no leftover hv-sysctl launchd service is running"

# kext state & ABI check
INFO="$("$RHV_INFO" 2>&1)" || true
if echo "$INFO" | grep -q "RyzenHV kext (ABI"; then
  KABI="$(echo "$INFO" | sed -n 's/.*(ABI \([0-9]*\)).*/\1/p' | head -1)"
  if [ -n "$BABI" ]; then
    [ "$KABI" = "$BABI" ] || fatal_state "kext ABI=${KABI} does not match bundle ABI=${BABI}. Install the matching kext and reboot."
    ok "kext loaded, ABI $KABI matches bundle"
  else
    ok "kext loaded, ABI $KABI"
  fi
  echo "$INFO" | grep -q "SVM  *: supported" && ok "SVM supported" || fatal_state "SVM is not enabled; enable SVM Mode (AMD-V) in BIOS"
  echo "$INFO" | grep -q "\[x\] NPT" && ok "nested paging (NPT) available" || fatal_state "nested paging (NPT) is not available"
else
  fatal_state "kext did not respond: check EFI/OC/Kexts, config.plist Kernel->Add, rhv_allow_users=1, or sandbox permissions. Details: $INFO"
  KABI="?"
fi

for t in plutil defaults pgrep hdiutil; do
  command -v "$t" >/dev/null 2>&1 || die "Missing required macOS command: ${t}"
done
[ -n "$PY" ] && ok "JSON backend: $PY" || warn "python3 not found, falling back to plutil for JSON; Xcode Command Line Tools recommended"

# Docker Desktop installation & version check
DOCKER_WRAPPED=0
DB=""
DV=""
if [ "$SKIP_DOCKER" -eq 0 ]; then
  if [ ! -d /Applications/Docker.app ]; then
    if [ "$INSTALL_DOCKER" -eq 1 ]; then
      warn "Docker Desktop not installed; will install ${DOCKER_VERSION_WANT} (${DOCKER_BUILD_WANT}) via --install-docker"
      DB="?"
      DV="?"
    else
      warn "Docker Desktop not installed; skipping Docker steps (pass --install-docker to auto-install ${DOCKER_VERSION_WANT})"
      SKIP_DOCKER=1
    fi
  else
    DB="$(defaults read /Applications/Docker.app/Contents/Info CFBundleVersion 2>/dev/null || echo '?')"
    DV="$(defaults read /Applications/Docker.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo '?')"
    if [ "$DB" = "$DOCKER_BUILD_WANT" ]; then
      ok "Docker Desktop $DV (build $DB) — recommended version (HyperKit + gRPC-FUSE + Host networking)"
    else
      warn "Installed Docker Desktop is $DV (build $DB); recommended version is ${DOCKER_VERSION_WANT} (build ${DOCKER_BUILD_WANT}) for HyperKit + gRPC-FUSE + Host networking"
      if [ "$DB" = "244584" ]; then
        warn "Docker Desktop 4.97.0 gRPC-FUSE may hang on host bind mounts under this setup."
      fi
      if [ "$INSTALL_DOCKER" -eq 1 ]; then
        ok "Will replace with ${DOCKER_VERSION_WANT} (${DOCKER_BUILD_WANT}) via --install-docker"
      else
        warn "Continuing with Docker Desktop $DV (build $DB) (pass --install-docker to install recommended version)"
      fi
    fi
    if docker_shim_status >/dev/null 2>&1; then
      DOCKER_WRAPPED=1
      ok "Docker Desktop is already wrapped (shim patch present)"
    fi
  fi
else
  warn "Skipping Docker (--skip-docker)"
fi

# Parallels Desktop check
PD_WRAPPED=0
if [ "$SKIP_PD" -eq 0 ]; then
  if [ ! -d "/Applications/Parallels Desktop.app" ]; then
    warn "Parallels Desktop not installed; skipping Parallels steps"
    SKIP_PD=1
  elif ! command -v prlctl >/dev/null 2>&1; then
    warn "prlctl not in PATH (Parallels Desktop incomplete or never launched); skipping Parallels steps"
    SKIP_PD=1
  else
    PB="$(defaults read "/Applications/Parallels Desktop.app/Contents/Info" CFBundleVersion 2>/dev/null || echo '?')"
    [ "$PB" = "$PD_BUILD_WANT" ] && ok "Parallels Desktop build ${PB} (tested build)" \
      || warn "Parallels build $PB differs from tested build ${PD_BUILD_WANT}; injection still works if binary layout matches"
    PSS="$(parallels_shim_status 2>/dev/null)"
    if [[ "$PSS" == *"private copy: present, mode: shim"* ]]; then
      PD_WRAPPED=1
      ok "Parallels Desktop is already wrapped (shim patch present)"
    else
      [ -f "$RHV_PRL_LIB" ] || die "Bundle is missing lib/libPrlXmlModel.1.dylib (required for Parallels shim); pass --skip-pd if not needed"
    fi
  fi
else
  warn "Skipping Parallels Desktop (--skip-pd)"
fi

if [ "$SKIP_DOCKER" -eq 1 ] && [ "$SKIP_PD" -eq 1 ]; then
  warn "Neither Docker Desktop nor Parallels Desktop is available; nothing to initialize."
  exit 0
fi

# VM state check
VM_RUNNING=""
if [ "$SKIP_PD" -eq 0 ]; then
  while read -r uuid status; do
    [ -z "$uuid" ] && continue
    [ "$status" = "stopped" ] || VM_RUNNING="$VM_RUNNING$uuid "
  done < <(prlctl list -a -o uuid,status 2>/dev/null | tail -n +2)
  if [ -n "$VM_RUNNING" ]; then
    if [ "$STOP_VMS" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ]; then
      warn "Running VMs will be stopped automatically (--stop-vms)"
    elif [ "$PD_WRAPPED" -eq 1 ]; then
      warn "Some VMs are not stopped; PD is already wrapped, so only 3D settings for running VMs will be skipped"
    else
      fatal_state "Some VMs are running/suspended; initialization requires them stopped.\n  Run 'prlctl list -a' and 'prlctl stop \"<VM name>\"', or pass --stop-vms."
    fi
  else
    ok "All Parallels VMs are stopped"
  fi
fi

# Docker running state check
DOCKER_RUNNING=0
if [ "$SKIP_DOCKER" -eq 0 ]; then
  pgrep -f "/Applications/Docker.app/Contents/MacOS/com.docker.backend" >/dev/null 2>&1 && DOCKER_RUNNING=1
  if [ "$DOCKER_RUNNING" -eq 1 ]; then
    if [ "$STOP_DOCKER" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ]; then
      warn "Running Docker Desktop will be stopped automatically (--stop-docker)"
    elif [ "$DOCKER_WRAPPED" -eq 1 ] && ! { [ "$INSTALL_DOCKER" -eq 1 ] && [ "$DB" != "$DOCKER_BUILD_WANT" ]; }; then
      warn "Docker Desktop is running; already wrapped, but settings changes require a Docker restart"
    else
      fatal_state "Docker Desktop is running and must be quit before patching.\n  Run /usr/local/bin/docker-down or quit from the menu bar, or pass --stop-docker."
    fi
  else
    ok "Docker Desktop is not running"
  fi
fi

if [ "$SKIP_PD" -eq 0 ] && [ "$PD_WRAPPED" -eq 0 ]; then
  sudo -n true >/dev/null 2>&1 || warn "Installing the Parallels wrapper requires sudo; you will be prompted for your password"
fi

# ---------------------------------------------------------------- Read-only diagnostic report
if [ "$CHECK_ONLY" -eq 1 ]; then
  step "--check Read-Only Diagnostic Report"
  say "  Component Shim Status:"
  if [ "$SKIP_DOCKER" -eq 0 ]; then
    say "    Docker Desktop Version    : ${DV:-?} (build ${DB:-?})"
    say "    Docker Desktop Shim       : $(docker_shim_status)"
    if [ "$DB" != "?" ] || { [ -n "$DV" ] && [ "$DV" != "?" ]; }; then
      if docker_uses_settings_store "$DV" "$DB"; then
        say "    Active Config (>=4.35.0)  : settings-store.json ($([ -f "$SETTINGS_STORE_JSON" ] && echo 'present' || echo 'missing'))"
      else
        say "    Active Config (<4.35.0)   : settings.json ($([ -f "$SETTINGS_JSON" ] && echo 'present' || echo 'missing'))"
      fi
    else
      say "    settings.json             : $([ -f "$SETTINGS_JSON" ] && echo 'present' || echo 'missing')"
      say "    settings-store.json       : $([ -f "$SETTINGS_STORE_JSON" ] && echo 'present' || echo 'missing')"
    fi
  fi
  if [ "$SKIP_PD" -eq 0 ]; then
    say "    Parallels Desktop Shim    : $(parallels_shim_status)"
  fi
  say "  Read-only check complete; no files were modified."
  [ "$CHECK_FAILS" -gt 0 ] && warn "Found $CHECK_FAILS issue(s); see warnings above" || ok "All checks passed; ready to initialize"
  say "  Run: \"$0\" --yes --stop-vms --stop-docker [--install-docker]"
  exit 0
fi

# ---------------------------------------------------------------- 2. Stop services
step "2/9  Stopping Docker / VMs"
if [ "$STOP_VMS" -eq 1 ] && [ -n "$VM_RUNNING" ] && [ "$SKIP_PD" -eq 0 ]; then
  for u in $VM_RUNNING; do
    run_timeout 90 prlctl stop "$u" >/dev/null 2>&1 || warn "VM $u did not stop gracefully"
  done
  ok "VMs stopped"
fi
if [ "$STOP_DOCKER" -eq 1 ] && [ "$DOCKER_RUNNING" -eq 1 ]; then
  if [ -x /usr/local/bin/docker-down ]; then /usr/local/bin/docker-down >/dev/null 2>&1
  else run_timeout 60 docker desktop stop >/dev/null 2>&1 || true; fi
  pkill -9 -f com.docker.hyperkit >/dev/null 2>&1 || true
  pkill -9 -f com.docker.backend >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Containers/com.docker.docker/Data/vms/0/hyperkit.pid" 2>/dev/null || true
  ok "Docker stopped and stale hyperkit.pid cleaned"
fi

# ---------------------------------------------------------------- 3. Core component check
step "3/9  System & core component verification"
if [ "$SKIP_DOCTOR" -eq 0 ]; then
  ok "kext (ABI $KABI), SVM Mode, and NPT Nested Paging are healthy"
  ok "boot-args contain required pure-shim flags (rhv_enable_svm, rhv_allow_users, amfi_get_out_of_my_way)"
  ok "Standalone initializer ready (independent of ./rhv hardcoded version & QEMU checks)"
else
  warn "Skipped component check (--skip-doctor)"
fi

# ---------------------------------------------------------------- 4. Install/verify Docker Desktop
step "4/9  Docker Desktop version check"
if [ "$SKIP_DOCKER" -eq 0 ] && [ "$INSTALL_DOCKER" -eq 1 ] && [ "$DB" != "$DOCKER_BUILD_WANT" ]; then
  DMG="${DOCKER_DMG:-$HOME/.ryzenhv/dl/Docker-${DOCKER_BUILD_WANT}.dmg}"
  mkdir -p "$(dirname "$DMG")"
  if [ ! -f "$DMG" ]; then
    say "  Downloading Docker Desktop ${DOCKER_VERSION_WANT} DMG: $DOCKER_DMG_URL"
    CURL_EXTRA=""
    case "${HTTPS_PROXY:-}" in *127.0.0.1*) CURL_EXTRA="--noproxy *" ;; esac
    # shellcheck disable=SC2086
    curl -fSL --retry 2 --max-time 900 $CURL_EXTRA -o "$DMG" "$DOCKER_DMG_URL" \
      || die "Failed to download ${DOCKER_VERSION_WANT}. Check network or pass --docker-dmg <path>."
  fi
  hdiutil imageinfo "$DMG" >/dev/null 2>&1 || die "$DMG is not a valid DMG file (incomplete download? Delete and retry)."
  MNT="$(mktemp -d /tmp/rhv-dd.XXXXXX)"
  hdiutil attach -readonly -nobrowse -noverify -mountpoint "$MNT" "$DMG" >/dev/null 2>&1 \
    || die "Failed to mount DMG: $DMG"
  NB="$(defaults read "$MNT/Docker.app/Contents/Info" CFBundleVersion 2>/dev/null || echo '?')"
  NV="$(defaults read "$MNT/Docker.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
  [ "$NB" = "$DOCKER_BUILD_WANT" ] || { hdiutil detach "$MNT" >/dev/null 2>&1; die "DMG contains ${NV} (build ${NB}), expected ${DOCKER_VERSION_WANT} (${DOCKER_BUILD_WANT})."; }
  is_docker_signed "$MNT/Docker.app/Contents/MacOS/com.docker.backend" \
    || { hdiutil detach "$MNT" >/dev/null 2>&1; die "App inside DMG failed official Docker signature check; aborting."; }

  [ -d /Applications/Docker.app ] && { trash /Applications/Docker.app 2>/dev/null || die "Failed to move existing /Applications/Docker.app to Trash; check permissions."; }
  cp -R "$MNT/Docker.app" /Applications/Docker.app || die "Failed to copy ${DOCKER_VERSION_WANT} to /Applications."
  hdiutil detach "$MNT" >/dev/null 2>&1 || true
  rmdir "$MNT" 2>/dev/null || true
  ok "Installed Docker Desktop ${NV} (${NB})"
  DB="$NB"
  DV="$NV"
  DOCKER_WRAPPED=0
fi
[ "$SKIP_DOCKER" -eq 0 ] && ok "Current Docker Desktop: ${DV:-?} (build $DB)"

# ---------------------------------------------------------------- 5. Docker shim patch
if [ "$SKIP_DOCKER" -eq 0 ]; then
  step "5/9  Docker Desktop shim patch"
  if [ "$DOCKER_WRAPPED" -eq 1 ]; then
    ok "Docker Desktop already wrapped; skipping"
  else
    docker_shim_install "$RHV_SHIM_LIB"
    DSS="$(docker_shim_status)"
    case "$DSS" in installed*) ;; *) die "Unexpected Docker Desktop wrapper state: $DSS" ;; esac
    ok "HyperKit and backend wrappers installed"
  fi
else
  step "5/9  Docker Desktop shim patch"
  warn "Docker Desktop not installed or skipped"
fi

# ---------------------------------------------------------------- 6. Docker settings (version-aware)
if [ "$SKIP_DOCKER" -eq 0 ]; then
  step "6/9  Configuring Docker settings & disabling auto-updates"
  mkdir -p "$SETTINGS_DIR"
  if docker_uses_settings_store "$DV" "$DB"; then
    # >= 4.35.0 (build 172550) uses settings-store.json (PascalCase keys)
    if [ ! -s "$SETTINGS_STORE_JSON" ]; then
      printf '%s\n' '{}' > "$SETTINGS_STORE_JSON"
      ok "Initialized settings-store.json"
    else
      backup_file "$SETTINGS_STORE_JSON"
    fi
    json_valid "$SETTINGS_STORE_JSON" || die "$SETTINGS_STORE_JSON is not valid JSON; restore it and retry"
    json_set "$SETTINGS_STORE_JSON" UseVirtualizationFramework bool false || die "Failed to set UseVirtualizationFramework"
    json_set "$SETTINGS_STORE_JSON" UseVirtualizationFrameworkVirtioFS bool false || die "Failed to set UseVirtualizationFrameworkVirtioFS"
    json_set "$SETTINGS_STORE_JSON" UseGrpcfuse bool true || die "Failed to set UseGrpcfuse"
    json_set "$SETTINGS_STORE_JSON" DisableUpdate bool true || die "Failed to set DisableUpdate"
    json_set "$SETTINGS_STORE_JSON" AutoDownloadUpdates bool false || die "Failed to set AutoDownloadUpdates"
    json_set "$SETTINGS_STORE_JSON" AcceptCanaryUpdates bool false || die "Failed to set AcceptCanaryUpdates"
    json_valid "$SETTINGS_STORE_JSON" || die "settings-store.json is invalid after modification"
    ok "settings-store.json (>= 4.35.0): HyperKit + gRPC-FUSE + auto-updates disabled"
  else
    # < 4.35.0 (build 172550) uses settings.json (camelCase keys)
    if [ ! -s "$SETTINGS_JSON" ]; then
      printf '%s\n' '{"settingsVersion":35,"filesharingDirectories":["/Users","/Volumes","/private","/tmp","/var/folders"]}' > "$SETTINGS_JSON"
      ok "Initialized settings.json"
    else
      backup_file "$SETTINGS_JSON"
    fi
    json_valid "$SETTINGS_JSON" || die "$SETTINGS_JSON is not valid JSON; restore it and retry"
    if [ -z "$(json_get "$SETTINGS_JSON" settingsVersion)" ]; then
      json_set "$SETTINGS_JSON" settingsVersion int 35 || die "Failed to set settingsVersion"
    fi
    json_set "$SETTINGS_JSON" useVirtualizationFramework bool false || die "Failed to set useVirtualizationFramework"
    json_set "$SETTINGS_JSON" useVirtualizationFrameworkVirtioFS bool false || die "Failed to set useVirtualizationFrameworkVirtioFS"
    json_set "$SETTINGS_JSON" useGrpcfuse bool true || die "Failed to set useGrpcfuse"
    json_set "$SETTINGS_JSON" filesharingDirectories json '["/Users","/Volumes","/private","/tmp","/var/folders"]' || die "Failed to set filesharingDirectories"
    json_set "$SETTINGS_JSON" disableUpdate bool true || die "Failed to set disableUpdate"
    json_set "$SETTINGS_JSON" autoDownloadUpdates bool false || die "Failed to set autoDownloadUpdates"
    json_set "$SETTINGS_JSON" acceptCanaryUpdates bool false || die "Failed to set acceptCanaryUpdates"
    json_valid "$SETTINGS_JSON" || die "settings.json is invalid after modification"
    ok "settings.json (< 4.35.0): HyperKit + gRPC-FUSE + file sharing + auto-updates disabled"
  fi
fi

# ---------------------------------------------------------------- 7. Parallels Desktop shim patch
if [ "$SKIP_PD" -eq 0 ]; then
  step "7/9  Parallels Desktop shim patch"
  if [ "$PD_WRAPPED" -eq 1 ]; then
    ok "Parallels Desktop already wrapped; skipping"
  else
    say "  Building private ~/.ryzenhv/prl copy and injecting stand-in library..."
    parallels_shim_prepare "$RHV_PRL_LIB"
    say "  Installing prl_vm_app wrapper via sudo (enter password if prompted):"
    parallels_shim_install
    PSS="$(parallels_shim_status)"
    case "$PSS" in *"wrapper installed"*) ;; *) die "PD wrapper not ready: $PSS" ;; esac
    ok "Parallels Desktop shim installed (mode=shim)"
  fi
else
  step "7/9  Parallels Desktop shim patch"
  warn "Parallels Desktop not installed or skipped"
fi

# ---------------------------------------------------------------- 8. VM 3D acceleration & PD preferences
GPU_VENDOR="unknown"
TARGET_3D="highest"
if [ "$SKIP_PD" -eq 0 ]; then
  step "8/9  VM 3D acceleration & Parallels auto-update settings"
  GPU_VENDOR="$(detect_gpu_vendor)"
  if [ "$KEEP_3D_OFF" -eq 1 ]; then
    TARGET_3D="off"
    warn "Disabling 3D acceleration (--keep-3d-off)"
  elif [ "$GPU_VENDOR" = "nvidia" ]; then
    TARGET_3D="off"
    warn "NVIDIA GPU / NVMTL driver detected: disabling Parallels 3D acceleration to avoid prl_vm_app crashes"
  elif [ "$GPU_VENDOR" = "amd" ]; then
    TARGET_3D="highest"
    ok "AMD GPU detected: enabling Parallels 3D acceleration (highest)"
  else
    TARGET_3D="highest"
    warn "Could not determine GPU vendor; defaulting Parallels 3D acceleration to highest (pass --keep-3d-off if using NVMTL)"
  fi

  N=0
  while read -r uuid status; do
    [ -z "$uuid" ] && continue
    [ "$status" = "stopped" ] || { warn "$uuid is $status; skipping 3D setting"; continue; }
    prlctl set "$uuid" --3d-accelerate "$TARGET_3D" >/dev/null 2>&1 \
      || die "Failed to set 3D acceleration ($TARGET_3D) for VM $uuid"
    VMI="$(prlctl list -i "$uuid" 2>/dev/null)"
    [[ "$VMI" == *"3d-acceleration=$TARGET_3D"* ]] \
      || die "Failed to verify 3d-acceleration=$TARGET_3D for VM $uuid"
    N=$((N+1)); ok "VM $uuid: 3d-acceleration=$TARGET_3D"
  done < <(prlctl list -a -o uuid,status 2>/dev/null | tail -n +2)
  [ "$N" -gt 0 ] || warn "No stopped VMs found; re-run this script after creating VMs to apply 3D settings"

  set_pd_pref() {
    local key="$1" want="$2" cur typ
    cur="$(defaults read "$PD_DOMAIN" "$key" 2>/dev/null || echo '')"
    typ="$(defaults read-type "$PD_DOMAIN" "$key" 2>/dev/null | sed 's/Type is //')"
    [ "$cur" = "$want" ] && { ok "$(basename "$key") is already $want"; return 0; }
    case "$typ" in
      integer) defaults write "$PD_DOMAIN" "$key" -int "$want" ;;
      boolean) defaults write "$PD_DOMAIN" "$key" -bool "$want" ;;
      *)       defaults write "$PD_DOMAIN" "$key" -string "$want" ;;
    esac || die "Failed to set Parallels preference: $key"
    ok "$key = $want"
  }
  set_pd_pref "Application preferences.Check for updates" "0"
  set_pd_pref "Application preferences.Download updates automatically" "0"
  set_pd_pref "ProductUpdate.UpdateTypeToInstallOnStart" "-1"
  ok "Parallels automatic update checks/downloads disabled"
fi

# ---------------------------------------------------------------- 9. Startup & smoke test
step "9/9  Startup verification & smoke test"
if [ "$RUN_VERIFY" -eq 1 ]; then
  if [ "$SKIP_DOCKER" -eq 0 ]; then
    run_smoke_test
  else
    warn "Skipped Docker smoke test (--skip-docker)"
  fi
else
  ok "Smoke test skipped by default (pass --smoke-test to verify, or run --smoke-only)"
fi

# ---------------------------------------------------------------- Summary
if [ "$SKIP_PD" -eq 1 ]; then
  PD_LINE="not installed or skipped"; D3_LINE="unchanged"
elif [ "$KEEP_3D_OFF" -eq 1 ]; then
  PD_LINE="$(defaults read "/Applications/Parallels Desktop.app/Contents/Info" CFBundleVersion 2>/dev/null || echo '?'), standalone shim"
  D3_LINE="off (--keep-3d-off)"
elif [ "$TARGET_3D" = "off" ]; then
  PD_LINE="$(defaults read "/Applications/Parallels Desktop.app/Contents/Info" CFBundleVersion 2>/dev/null || echo '?'), standalone shim"
  D3_LINE="off (NVIDIA/NVMTL detected)"
else
  PD_LINE="$(defaults read "/Applications/Parallels Desktop.app/Contents/Info" CFBundleVersion 2>/dev/null || echo '?'), standalone shim"
  D3_LINE="highest (GPU: $GPU_VENDOR)"
fi
if [ "$SKIP_DOCKER" -eq 1 ]; then
  DD_LINE="not installed or skipped"
else
  DD_LINE="$(defaults read /Applications/Docker.app/Contents/Info CFBundleShortVersionString 2>/dev/null) (build $DB)"
fi

cat <<EOF

$C_B================ Initialization Complete (Standalone) ================$C_N
  RyzenHV        : ${BVER:-unknown} (ABI ${BABI:-unknown})  [$RHV_DIR]
  Mode           : Pure shim mode (no rhv_hv=1 in boot-args)
  Architecture   : Standalone (zero dependency on libexec/*.sh or ./rhv)
  Docker Desktop : $DD_LINE
  Docker Engine  : HyperKit + gRPC-FUSE (version-aware config applied, auto-updates off)
  Parallels      : $PD_LINE
  3D Mode        : $D3_LINE
  Log file       : $LOG

  Common commands:
    ./rhv-init-apps.sh --check        # Read-only status check
    ./rhv-init-apps.sh --smoke-only   # Run bind-mount smoke test
    ./rhv-init-apps.sh --smoke-test   # Re-initialize and run smoke test
    ./rhv-init-apps.sh --undo         # Restore original Docker & Parallels files

  Notes:
    * < 4.35.0 uses settings.json; >= 4.35.0 uses settings-store.json (auto-detected).
    * Recommended Docker Desktop: ${DOCKER_VERSION_WANT} (${DOCKER_BUILD_WANT}) for HyperKit + gRPC-FUSE + Host networking.
    * Never enable "Use Virtualization framework" in Docker Desktop settings (RyzenHV cannot serve Apple VZ).
$C_B========================================================================$C_N
EOF
log "done successfully"
exit 0
