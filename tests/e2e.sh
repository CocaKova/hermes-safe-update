#!/bin/bash
# End-to-end test against a REAL stock Hermes install fed by a local fake upstream.
#
#   ⚠ Run this on a throwaway VM, container or user account. It installs Hermes into ~/.hermes,
#     installs and restarts a gateway service, and force-pushes to its own fake upstream repo.
#
#   tests/e2e.sh --setup          build the fake upstream, install Hermes, install the gateway
#   tests/e2e.sh [SCENARIO ...]   run scenarios (default: all, in order)
#
# Scenarios (each leaves the fake upstream healthy for the next one):
#   success       a harmless upstream commit                    → exit 0, checkout on it
#   crash         the gateway crashes on start                  → exit 3, checkout restored
#   platform      the API server adapter never connects         → exit 3, checkout restored
#   ignore        same, with --ignore-platform api_server       → exit 0
#   dirty         a modified tracked file in the checkout       → exit 1, nothing touched
#   preflight     a checks.d hook that fails before the update  → exit 1, nothing touched
#   detached      checkout on a detached HEAD (release channel) → exit 0, then rollback → detached
#   nogateway     no gateway running (CLI-only user)            → exit 0
#   foreground    gateway run in the foreground, no service     → exit 0 or 3, never 4
#   fgcrash       foreground gateway + an update that crashes it → exit 3, relaunched detached
#   rollback      --rollback to the first snapshot              → exit 0, checkout on the base
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${HSU_E2E_DIR:-$HOME/hsu-e2e}"
SRC="$WORK/src"
UP="$WORK/upstream.git"
OPTS=(-y --no-turn --keep 50 --settle 10 --gateway-timeout 90 --platform-timeout 45 --restart-timeout 120)
export HSU_CONFIG_DIR="$WORK/hsu-config"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) WINDOWS=1; HH="$(cygpath -u "$LOCALAPPDATA")/hermes"; export PATH="$HH/bin:$PATH" ;;
    *) WINDOWS=0; HH="$HOME/.hermes"; export PATH="$HOME/.local/bin:$PATH" ;;
esac
TREE_DIR="$HH/hermes-agent"
PY="$(command -v python3 || command -v python)"
hsu() { "$PY" "$HERE/hermes-safe-update" "$@"; }

platform_up() { HH_STATE="$HH/gateway_state.json" PLATFORM="$1" "$PY" - <<'P'
import json, os, sys
try:
    d = json.load(open(os.environ["HH_STATE"]))
except (OSError, ValueError):
    sys.exit(1)
p = (d.get("platforms") or {}).get(os.environ["PLATFORM"]) or {}
sys.exit(0 if p.get("state") == "connected" and p.get("writer_pid") == d.get("pid") else 1)
P
}
gateway_up() { HH_STATE="$HH/gateway_state.json" "$PY" - <<'P'
import json, os, sys
try:
    d = json.load(open(os.environ["HH_STATE"]))
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if d.get("gateway_state") in ("running", "degraded") else 1)
P
}

if [ "${1:-}" = "--setup" ]; then
    shift
    [ -e "$HH" ] && { echo "$HH exists; refusing to install over it"; exit 2; }
    mkdir -p "$WORK" && cd "$WORK" || exit 2
    # A single-commit copy of current upstream: shallow clones break the installer's fetch.
    git clone -q --depth 1 https://github.com/NousResearch/hermes-agent.git src || exit 2
    cd "$SRC" && git config user.email e2e@localhost && git config user.name e2e
    git checkout -q --orphan fake && git commit -qm "fake upstream base" || exit 2
    git init -q --bare "$UP" && git push -q "$UP" fake:main || exit 2
    git remote set-url origin "$UP" && git fetch -q origin && git checkout -q -B main origin/main
    if [ "$WINDOWS" = 1 ]; then
        HERMES_REPO_URL="$(cygpath -w "$UP")" powershell -NoProfile -ExecutionPolicy Bypass \
            -File scripts/install.ps1 -NonInteractive -SkipBrowser || exit 2
    else
        HERMES_REPO_URL="$UP" bash scripts/install.sh --non-interactive --skip-browser || exit 2
    fi
    # Two platforms that need no accounts, so losing one does not stop the whole gateway.
    # Hermes refuses an API_SERVER_KEY shorter than 16 characters.
    printf 'API_SERVER_ENABLED=true\nAPI_SERVER_KEY=e2e-%s\nWEBHOOK_ENABLED=true\n' \
        "$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')" >> "$HH/.env"
    hermes gateway install </dev/null || exit 2
    hermes gateway start </dev/null >/dev/null 2>&1 || true
    for _ in $(seq 1 90); do gateway_up && break; sleep 2; done
    gateway_up || { echo "the gateway did not come up after install"; exit 2; }
fi

cd "$SRC" || { echo "run with --setup first"; exit 2; }
FAILED=()
tree() { git -C "$TREE_DIR" rev-parse HEAD; }
branch() { git -C "$TREE_DIR" rev-parse --abbrev-ref HEAD; }
expect() { # name expected actual
    if [ "$2" = "$3" ]; then echo "PASS $1 (exit $3)"; else echo "FAIL $1: expected exit $2, got $3"; FAILED+=("$1"); fi
}
check() { # name condition-description command...
    local name="$1" what="$2"; shift 2
    if "$@"; then echo "PASS $name: $what"; else echo "FAIL $name: $what"; FAILED+=("$name"); fi
}
push_commit() { git commit -qam "$1" && git push -q -f origin main; }
heal() { # put the fake upstream back on a healthy tree with one more harmless commit
    git checkout -q "$PRISTINE" -- gateway
    mkdir -p docs && date > docs/hsu-e2e.txt && git add -A docs gateway && git commit -qm "heal" && git push -q -f origin main
}
break_gateway() {
    "$PY" - <<'P'
p = 'gateway/run.py'; s = open(p, encoding='utf-8').read()
i = s.index('async def start_gateway(')
k = s.index('"""', s.index('"""', i) + 3) + 3       # end of the docstring
open(p, 'w', encoding='utf-8').write(s[:k] + '\n    raise RuntimeError("e2e: simulated broken gateway")' + s[k:])
P
}
break_api_server() {
    "$PY" - <<'P'
p = 'gateway/platforms/api_server.py'; s = open(p, encoding='utf-8').read()
a = '        """Start the aiohttp web server."""\n'
assert s.count(a) == 1, "api_server.connect moved; update this test"
open(p, 'w', encoding='utf-8').write(s.replace(a, a + '        logger.error("e2e: simulated adapter failure")\n        return False\n'))
P
}

# The fake upstream's first commit is an untouched copy of real upstream. Start from its gateway
# code, so a run that was interrupted halfway through a "broken" scenario can't poison this one.
PRISTINE="$(git rev-list --max-parents=0 HEAD | tail -1)"
git checkout -q "$PRISTINE" -- gateway
if ! git diff --cached --quiet; then git commit -qm "normalize" && git push -q -f origin main; fi
BASE="$(tree)"

s_success() {
    mkdir -p docs && date > docs/hsu-e2e.txt && git add docs && git commit -qm "harmless" && git push -q -f origin main
    hsu "${OPTS[@]}"; expect success 0 $?
    check success "checkout on the new commit" test "$(tree)" = "$(git rev-parse HEAD)"
}
s_crash() {
    local before; before="$(tree)"
    break_gateway; push_commit "gateway crashes"
    hsu "${OPTS[@]}"; expect crash 3 $?
    check crash "checkout restored" test "$(tree)" = "$before"
    check crash "gateway running again" gateway_up
    heal
}
s_platform() {
    local before; before="$(tree)"
    for _ in $(seq 1 30); do platform_up api_server && break; sleep 2; done
    check platform "precondition: api_server connected before the update" platform_up api_server
    break_api_server; push_commit "api_server never connects"
    hsu "${OPTS[@]}"; expect platform 3 $?
    check platform "checkout restored" test "$(tree)" = "$before"
    heal
}
s_ignore() {
    break_api_server; push_commit "api_server never connects (ignored)"
    hsu "${OPTS[@]}" --ignore-platform api_server; expect ignore 0 $?
    heal
    hsu "${OPTS[@]}"; expect ignore-recover 0 $?
}
s_dirty() {
    local f="$TREE_DIR/README.md" before; before="$(tree)"
    echo "local edit" >> "$f"
    heal
    hsu "${OPTS[@]}"; expect dirty 1 $?
    check dirty "checkout untouched" test "$(tree)" = "$before"
    git -C "$TREE_DIR" checkout -q -- README.md
}
s_preflight() {
    local d="$HSU_CONFIG_DIR/checks.d" before; before="$(tree)"
    mkdir -p "$d"
    # Python, so the same hook runs on Windows too.
    printf '#!/usr/bin/env python3\nimport os, sys\nif os.environ.get("HSU_PHASE") == "preflight":\n    print("e2e: failing on purpose"); sys.exit(1)\n' > "$d/50-e2e-fail.py"
    chmod +x "$d/50-e2e-fail.py"
    hsu "${OPTS[@]}"; expect preflight 1 $?
    check preflight "checkout untouched" test "$(tree)" = "$before"
    rm -f "$d/50-e2e-fail.py"
}
s_detached() {
    local before; before="$(tree)"
    git -C "$TREE_DIR" checkout -q --detach
    heal
    hsu "${OPTS[@]}"; local rc=$?
    expect detached 0 $rc
    local snap; snap="$(hsu --list | tail -1 | awk '{print $1}')"
    hsu --rollback "$snap" --no-turn --settle 10; expect detached-rollback 0 $?
    check detached "restored as a detached HEAD at the old commit" test "$(branch) $(tree)" = "HEAD $before"
    git -C "$TREE_DIR" checkout -q main
    hsu "${OPTS[@]}" >/dev/null
}
s_nogateway() {
    hermes gateway stop </dev/null >/dev/null 2>&1
    heal
    hsu "${OPTS[@]}"; expect nogateway 0 $?
    hermes gateway start </dev/null >/dev/null 2>&1
}
s_foreground() {
    if [ "$WINDOWS" = 1 ]; then echo "SKIP foreground: POSIX only (Windows gateways run from a scheduled task)"; return; fi
    hermes gateway stop </dev/null >/dev/null 2>&1
    ( nohup hermes gateway run >"$WORK/foreground.log" 2>&1 & )
    for _ in $(seq 1 60); do gateway_up && break; sleep 2; done
    heal
    hsu "${OPTS[@]}"; local rc=$?
    echo "foreground: exit $rc (0 = upstream restarted the foreground gateway, 3 = it could not and we rolled back)"
    check foreground "never ROLLBACK UNHEALTHY" test "$rc" != 4
    pkill -f "gateway run" 2>/dev/null; sleep 3
    hermes gateway start </dev/null >/dev/null 2>&1
    hsu "${OPTS[@]}" >/dev/null
}
s_fgcrash() {
    if [ "$WINDOWS" = 1 ]; then echo "SKIP fgcrash: POSIX only"; return; fi
    local before; before="$(tree)"
    # No service at all, the way a tmux, WSL or container user runs it.
    hermes gateway stop </dev/null >/dev/null 2>&1
    hermes gateway uninstall </dev/null >/dev/null 2>&1
    ( nohup hermes gateway run >"$WORK/foreground.log" 2>&1 & )
    for _ in $(seq 1 60); do gateway_up && break; sleep 2; done
    break_gateway; push_commit "gateway crashes (foreground)"
    hsu "${OPTS[@]}"; expect fgcrash 3 $?
    check fgcrash "checkout restored" test "$(tree)" = "$before"
    for _ in $(seq 1 30); do gateway_up && break; sleep 2; done
    check fgcrash "gateway running again (relaunched detached)" gateway_up
    pkill -f "gateway run" 2>/dev/null; sleep 3
    hermes gateway install </dev/null >/dev/null 2>&1
    hermes gateway start </dev/null >/dev/null 2>&1
    for _ in $(seq 1 60); do gateway_up && break; sleep 2; done
    heal
    hsu "${OPTS[@]}" >/dev/null
}
s_rollback() {
    local first; first="$(hsu --list | head -1 | awk '{print $1}')"
    hsu --rollback "$first" --no-turn --settle 10; expect rollback 0 $?
    check rollback "checkout back on the base" test "$(tree)" = "$BASE"
}

SCENARIOS=("$@")
[ "${SCENARIOS[*]:-}" = "none" ] && { echo "setup done"; exit 0; }
[ ${#SCENARIOS[@]} -eq 0 ] && SCENARIOS=(success crash platform ignore dirty preflight detached nogateway foreground fgcrash rollback)
for s in "${SCENARIOS[@]}"; do
    echo; echo "########## $s"
    "s_$s"
done
echo
if [ ${#FAILED[@]} -eq 0 ]; then echo "E2E: ALL PASS (${SCENARIOS[*]})"; exit 0; fi
echo "E2E: FAILED: ${FAILED[*]}"; exit 1
