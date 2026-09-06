#!/usr/bin/env bash
# miniclosedai-node — one-line installer for a compute (and optionally
# voice) node on the interdata network. Linux + macOS. See install.ps1 for
# the Windows/PowerShell equivalent — a true single polyglot script isn't
# practical for something this involved, so this is one canonical command
# per platform, both producing the same end state.
#
# Quick install:
#   curl -fsSL https://raw.githubusercontent.com/edantonio505/miniclosedai-node/main/install.sh | bash
#
# What it does:
#   1. Takes an enrollment token (minted by an admin in miniaicloud's admin
#      panel: Node tokens page) — interactively, or via
#      MINICLOSEDAI_NODE_TOKEN to skip the prompt.
#   2. Installs Ollama (official installer) and pulls the model — default
#      qwen3.5:9b-q4_K_M, 6.6GB, chosen specifically because it fits an
#      8GB-VRAM card with headroom (the bare qwen3.5:9b tag and the q8_0
#      variant, at 11GB, do not).
#   3. Asks whether to also run a local Latina voice pod (latinavoicepod) on
#      this node — Linux only (its own start.sh assumes apt-get + a
#      CUDA-matched torch build). Skip if this node is already tight on
#      VRAM: qwen3.5:9b-q4_K_M plus a second GPU model competes for the
#      same 8GB. You can add/remove a voice pod on a node later from
#      miniaicloud's admin panel without re-running this installer, once
#      that remote-control piece (a later phase of this project) exists.
#   4. Installs Tailscale, exchanges the enrollment token for a join key via
#      miniaicloud's POST /api/nodes/enroll, runs `tailscale up --ssh`, then
#      reports this node's tailnet IP back via POST /api/nodes/register —
#      the node is enabled on the interdata network immediately, no extra
#      manual admin-approval step (the enrollment token itself is the trust
#      gate). The admin can SSH straight to this node's tailnet IP from
#      anywhere afterward, and lock it out (disable + remove from the
#      tailnet in one action) from miniaicloud's Backends page.
#   5. Installs the `ask` CLI (edstui) via pipx — same pattern as
#      miniclosedai's own installer.
#
# Env vars (all optional except the token, which the script will prompt for
# if not set):
#   MINICLOSEDAI_HUB_URL      miniaicloud base URL (default: https://app.interdataresearch.ai)
#   MINICLOSEDAI_NODE_TOKEN   enrollment token — skips the interactive prompt
#   MINICLOSEDAI_NODE_NAME    this node's name on the network (default: hostname)
#   MINICLOSEDAI_NODE_VOICE   1/0 — install a local Latina voice pod (skips the prompt)
#   OLLAMA_MODEL              model to pull (default: qwen3.5:9b-q4_K_M)
#   OLLAMA_PORT               port Ollama listens on (default: 11434)
#   LATINA_DIR                where to clone latinavoicepod (default: $HOME/latinavoicepod)
#   ASK_REPO                  edstui repo to pipx-install (default: git+https://github.com/edantonio505/edstui.git)

set -euo pipefail

HUB_URL="${MINICLOSEDAI_HUB_URL:-https://app.interdataresearch.ai}"
NODE_NAME="${MINICLOSEDAI_NODE_NAME:-$(hostname)}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.5:9b-q4_K_M}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
LATINA_DIR="${LATINA_DIR:-$HOME/latinavoicepod}"
ASK_REPO="${ASK_REPO:-git+https://github.com/edantonio505/edstui.git}"

if [ -t 1 ]; then
    BOLD=$'\e[1m'; GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; RST=$'\e[0m'
else
    BOLD=''; GREEN=''; RED=''; DIM=''; RST=''
fi
say()  { printf '%s\n' "$1"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RST" "$1"; }
warn() { printf '%s!%s %s\n' "$RED"   "$RST" "$1" >&2; }
fail() { warn "$1"; exit 1; }

OS="$(uname -s)"

printf '%sminiclosedai-node installer%s\n' "$BOLD" "$RST"
printf '%s  hub:  %s%s\n' "$DIM" "$HUB_URL" "$RST"
printf '%s  name: %s%s\n' "$DIM" "$NODE_NAME" "$RST"
echo

need() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required tool: $1. Install it, then re-run."
}
need curl
need python3

# `curl ... | bash` (the documented one-liner) feeds this whole script in on
# stdin, so a plain `read` here would immediately hit EOF instead of
# prompting. Read from the controlling terminal directly instead — works
# even with stdin occupied, as long as one is actually attached.
prompt() {
    if [ -r /dev/tty ]; then
        printf '%s' "$1" > /dev/tty
        read -r REPLY < /dev/tty
    else
        REPLY=""
    fi
}

# ---------- 1. Enrollment token ----------
if [ -n "${MINICLOSEDAI_NODE_TOKEN:-}" ]; then
    TOKEN="$MINICLOSEDAI_NODE_TOKEN"
else
    prompt 'Enrollment token (from miniaicloud admin -> Node tokens): '
    TOKEN="$REPLY"
fi
[ -n "$TOKEN" ] || fail "An enrollment token is required — mint one in miniaicloud's admin panel first (or set MINICLOSEDAI_NODE_TOKEN, e.g. when no terminal is attached)."

# ---------- 2. Ollama + model ----------
if ! command -v ollama >/dev/null 2>&1; then
    say "Installing Ollama…"
    curl -fsSL https://ollama.com/install.sh | sh
    ok "Ollama installed"
else
    ok "Ollama already installed"
fi

# The official Linux installer registers a systemd service that starts
# automatically; on macOS the Ollama app/CLI serves on demand. Either way,
# make sure something is actually listening before we try to pull.
if ! curl -sf -m 2 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1; then
    say "Starting Ollama…"
    nohup ollama serve >/tmp/miniclosedai-node-ollama.log 2>&1 &
    disown
    for _ in $(seq 1 20); do
        sleep 0.5
        curl -sf -m 2 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1 && break
    done
fi
curl -sf -m 2 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1 \
    || fail "Ollama isn't answering on :${OLLAMA_PORT} — check /tmp/miniclosedai-node-ollama.log"

say "Pulling ${OLLAMA_MODEL} (fits an 8GB card with headroom)…"
ollama pull "$OLLAMA_MODEL"
ok "model ready: $OLLAMA_MODEL"

# ---------- 3. Optional local voice pod (Linux only) ----------
if [ -n "${MINICLOSEDAI_NODE_VOICE:-}" ]; then
    WANT_VOICE="$MINICLOSEDAI_NODE_VOICE"
else
    WANT_VOICE=0
    if [ "$OS" = "Linux" ]; then
        prompt 'Install a local Latina voice pod on this node too? (uses more VRAM) [y/N] '
        case "$REPLY" in [Yy]*) WANT_VOICE=1 ;; esac
    fi
fi

if [ "$WANT_VOICE" = "1" ]; then
    if [ "$OS" != "Linux" ]; then
        warn "Local Latina voice pod install is Linux-only (its start.sh assumes apt-get) — skipping on $OS."
    else
        need git
        if [ -d "$LATINA_DIR/.git" ]; then
            say "latinavoicepod: existing checkout — pulling"
            git -C "$LATINA_DIR" pull --quiet
        else
            say "Cloning latinavoicepod…"
            git clone --quiet https://github.com/edantonio505/latinavoicepod.git "$LATINA_DIR"
        fi
        say "Setting up latinavoicepod (installs its own CUDA-matched torch — can take a while)…"
        ( cd "$LATINA_DIR" && ./start.sh --setup-only )
        say "Starting latinavoicepod (detached)…"
        ( cd "$LATINA_DIR" && nohup ./start.sh >/tmp/miniclosedai-node-latina.log 2>&1 & disown )
        for _ in $(seq 1 30); do
            sleep 1
            curl -sf -m 2 "http://127.0.0.1:${LATINA_PORT:-8000}/health" >/dev/null 2>&1 && break
        done
        if curl -sf -m 2 "http://127.0.0.1:${LATINA_PORT:-8000}/health" >/dev/null 2>&1; then
            ok "latinavoicepod running on :${LATINA_PORT:-8000} (log: /tmp/miniclosedai-node-latina.log)"
        else
            warn "latinavoicepod didn't answer yet — it may still be downloading weights. Check /tmp/miniclosedai-node-latina.log"
        fi
    fi
fi

# ---------- 4. Tailscale: enroll -> join -> register ----------
if ! command -v tailscale >/dev/null 2>&1; then
    say "Installing Tailscale…"
    if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
        # Homebrew's tailscaled runs as a real launchd system service, unlike
        # the App Store GUI app — the one that actually works headless.
        brew install tailscale
        sudo brew services start tailscale
    else
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    ok "Tailscale installed"
else
    ok "Tailscale already installed"
fi

# POST $1=path $2=json-body. Prints the response body on 2xx; on any other
# status, fails with the actual HTTP status + response body — a bad token
# (401), Tailscale not yet configured on the hub (503), or a stale deploy
# (404) each look different, and a bare "curl failed" hid that distinction.
hub_post() {
    local path="$1" body="$2" raw status resp
    raw="$(curl -s -m 30 -w '\n%{http_code}' -X POST "$HUB_URL$path" \
        -H 'Content-Type: application/json' -d "$body")" \
        || fail "$HUB_URL$path — not reachable (network/DNS)."
    status="${raw##*$'\n'}"
    resp="${raw%$'\n'*}"
    if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
        fail "$HUB_URL$path -> HTTP $status: $resp"
    fi
    printf '%s' "$resp"
}

say "Requesting a Tailscale join key from $HUB_URL…"
ENROLL_RESP="$(hub_post /api/nodes/enroll "{\"token\":\"$TOKEN\"}")"
AUTHKEY="$(printf '%s' "$ENROLL_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tailscale_authkey"])')"
[ -n "$AUTHKEY" ] || fail "Hub didn't return a Tailscale auth key: $ENROLL_RESP"

say "Joining the tailnet (this also enables Tailscale SSH — no separate keys to manage)…"
SUDO=""; [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
$SUDO tailscale up --authkey="$AUTHKEY" --ssh --hostname="$NODE_NAME" --accept-routes
ok "joined the tailnet as $NODE_NAME"

TS_IP=""
for _ in $(seq 1 10); do
    TS_IP="$($SUDO tailscale ip -4 2>/dev/null || true)"
    [ -n "$TS_IP" ] && break
    sleep 1
done
[ -n "$TS_IP" ] || fail "Joined the tailnet but couldn't read this node's IP (tailscale ip -4)."
ok "tailnet IP: $TS_IP"

say "Registering with $HUB_URL as an enabled backend…"
REGISTER_RESP="$(hub_post /api/nodes/register "{\"token\":\"$TOKEN\",\"name\":\"$NODE_NAME\",\"tailscale_ip\":\"$TS_IP\",\"ollama_port\":$OLLAMA_PORT}")"
ok "registered: $REGISTER_RESP"

# ---------- 5. ask (edstui) ----------
if ! command -v pipx >/dev/null 2>&1; then
    say "Installing pipx (for the \`ask\` CLI)…"
    python3 -m pip install -q --user pipx || warn "could not install pipx — skipping \`ask\` setup"
    python3 -m pipx ensurepath >/dev/null 2>&1 || true
    export PATH="$HOME/.local/bin:$PATH"
fi
if command -v pipx >/dev/null 2>&1; then
    say "Installing the \`ask\` CLI (edstui)…"
    pipx install --quiet --force "$ASK_REPO" && ok "ask CLI ready — run \`ask\` from any shell" \
        || warn "pipx install of $ASK_REPO failed — re-run later: pipx install --force $ASK_REPO"
fi

echo
printf '%s%s✓ Node enrolled on the interdata network%s\n' "$BOLD" "$GREEN" "$RST"
printf '  tailnet IP: %s   model: %s\n' "$TS_IP" "$OLLAMA_MODEL"
printf '  Admin can now SSH in with: tailscale ssh %s\n' "$NODE_NAME"
