#!/usr/bin/env bash
# Local Docker-based smoke test for install.sh — catches "assumed present"
# OS-dependency bugs (like the missing-`git` bug that silently broke `ask`
# installs on real hardware) here, on a dev machine, before burning a
# round-trip on real hardware.
#
# Runs install.sh inside a container that mirrors a normal Ubuntu
# desktop/server box: curl, python3, ca-certificates and iproute2 (`ss`)
# preinstalled — every real Ubuntu install already has these, and the
# documented `curl -fsSL ... | bash` one-liner itself requires curl to
# already exist just to fetch this script — but deliberately WITHOUT git or
# Node.js/npm preinstalled, since those are exactly what install.sh must
# install for itself (git for the optional latinavoicepod/HF clones; Node.js
# because `ask`, published to npm as eds-tui, needs >=20 and a fresh Ubuntu
# box has none at all).
#
# What this DOES validate, for real: git auto-install, Node.js auto-install
# (NodeSource + apt path), `npm install -g eds-tui` actually succeeding,
# Ollama installing + pulling a real (small) model in CPU mode, the model
# loading and staying resident, and the bind-to-all-interfaces check running
# for real (iproute2/`ss` is present). The container also has no systemd
# (PID 1 is just bash) — same as most containers and non-systemd hosts — so
# this exercises install.sh's non-systemd fallback path along the way.
#
# What this CANNOT validate: real GPU inference, or the actual network path
# a real relay would use to reach the node over Tailscale — both need real
# hardware/a real tailnet. Node registration is therefore expected to fail
# here (no real enrollment token by default) — the harness treats that as a
# PASS as long as everything before it, the actual OS-dependency chain this
# exists to catch, completed successfully.
#
# Usage:
#   test/docker-smoke.sh
#   MINICLOSEDAI_NODE_TOKEN=<real> MINICLOSEDAI_HUB_URL=<real> \
#     DOCKER_SMOKE_TAILSCALE=1 test/docker-smoke.sh
#       (stretch goal: a real Tailscale join test — needs a real hub + a
#       real enrollment token, and grants the container the extra
#       capabilities Tailscale needs: --cap-add=NET_ADMIN --device=/dev/net/tun)

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
INSTALL_SH="$(pwd)/install.sh"
[ -f "$INSTALL_SH" ] || { echo "install.sh not found at $INSTALL_SH" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || { echo "docker is required for this harness" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable — is it running?" >&2; exit 1; }

IMAGE="ubuntu:24.04"
TEST_MODEL="${DOCKER_SMOKE_MODEL:-qwen2.5:0.5b}"   # small + fast, real end-to-end pull+load
TOKEN="${MINICLOSEDAI_NODE_TOKEN:-docker-smoke-test-fake-token}"
LOG="$(mktemp)"

DOCKER_ARGS=(--rm
    -v "$INSTALL_SH:/install.sh:ro"
    -e "DEBIAN_FRONTEND=noninteractive"
    -e "MINICLOSEDAI_NODE_TOKEN=$TOKEN"
    -e "MINICLOSEDAI_NODE_VOICE=0"
    -e "OLLAMA_MODEL=$TEST_MODEL"
)
[ -n "${MINICLOSEDAI_HUB_URL:-}" ] && DOCKER_ARGS+=(-e "MINICLOSEDAI_HUB_URL=$MINICLOSEDAI_HUB_URL")

if [ "${DOCKER_SMOKE_TAILSCALE:-0}" = "1" ]; then
    echo "Tailscale join test requested — granting NET_ADMIN + /dev/net/tun."
    DOCKER_ARGS+=(--cap-add=NET_ADMIN --device=/dev/net/tun)
fi

BOOTSTRAP='apt-get update -qq && apt-get install -y -qq curl python3 ca-certificates iproute2 && bash /install.sh'

echo "Running install.sh inside a clean ${IMAGE} container (curl/python3/ss preinstalled, git/Node.js deliberately not)…"
echo "(full transcript: $LOG)"
echo

set +e
docker run "${DOCKER_ARGS[@]}" "$IMAGE" bash -c "$BOOTSTRAP" 2>&1 | tee "$LOG"
EXIT_CODE="${PIPESTATUS[0]}"
set -e

echo
echo "----------------------------------------"

FAIL=0
check() {
    if grep -qF "$2" "$LOG"; then
        printf '✓ %s\n' "$1"
    else
        printf '✗ %s\n' "$1"
        FAIL=1
    fi
}

check "git auto-installed"          "git installed"
check "Node.js bootstrap reached"   "Installing Node.js"
check "ask CLI installed via npm"   "ask CLI ready"
# "model ready" can only be reached if the bind-to-all-interfaces check
# (real, since iproute2/`ss` is installed) already passed — a failed check
# calls fail() and halts the script before ever pulling the model, on both
# the systemd and non-systemd paths — so this one line also covers that.
check "Ollama installed + model pulled" "model ready: $TEST_MODEL"
check "model loaded and resident"   "model loaded and resident"

# Node registration is EXPECTED to fail without a real token/tailnet — that
# is not what this harness exists to prove. Only fail the run if something
# EARLIER (the actual OS-dependency chain) broke, or if the script died for
# a reason this harness doesn't recognize at all.
if grep -qF "Node enrolled on the interdata network" "$LOG"; then
    echo "✓ full end-to-end registration also succeeded (a real token/tailnet were provided)"
elif grep -qE "not reachable \(network/DNS\)|-> HTTP [0-9]+:|Joined the tailnet but couldn't|still isn't listening" "$LOG"; then
    echo "· registration step failed as expected without a real token/tailnet (not a harness failure)"
else
    echo "✗ script exited (code $EXIT_CODE) without reaching, or failing at, a recognized registration step — inspect $LOG"
    FAIL=1
fi

echo "----------------------------------------"
if [ "$FAIL" = "0" ]; then
    echo "PASS — the OS-dependency chain (git, Node.js, ask, Ollama) completed successfully."
    exit 0
else
    echo "FAIL — see $LOG for the full transcript."
    exit 1
fi
