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
#      qwen3.5:4b (~3.4GB weights), chosen so the total loaded footprint
#      stays comfortably under 6GB even with a real 32768-token context
#      (~4.4GB total, measured) — leaving actual headroom on an 8GB card,
#      unlike the 9b variant (6.6GB in weights alone, already over a 6GB
#      budget before any context/overhead). Sets OLLAMA_CONTEXT_LENGTH
#      explicitly rather than trusting Ollama's own VRAM-tiered default
#      (which would otherwise silently land on a cramped 4096 tokens on an
#      8GB card), OLLAMA_KEEP_ALIVE=-1, and explicitly loads the model into
#      memory right away, so it stays resident forever instead of unloading
#      after Ollama's default 5-minute idle timeout — the relay may route
#      to this node unpredictably, and a cold-load on the first request
#      after any quiet period would be bad latency.
#   3. Installs the `ask` CLI (edstui) via pipx — same pattern as
#      miniclosedai's own installer. Deliberately done before network
#      registration below, so a node still ends up with `ask` even if
#      Tailscale/registration fails — useful for debugging exactly that.
#      Then optionally configures `ask` to reach the interdata relay
#      DIRECTLY (miniaicloud exposes a native Ollama API at $HUB_URL/api/*,
#      not just this node's own small model) — needs a relay API key (an
#      admin-minted ApiKey, NOT this node's own node_api_key — a separate
#      credential), prompted for or via MINICLOSEDAI_NODE_ASK_API_KEY.
#      Blank/skipped leaves `ask` installed but unconfigured.
#   4. Asks whether to also run a local Latina voice pod (latinavoicepod) on
#      this node — Linux only (its own start.sh assumes apt-get + a
#      CUDA-matched torch build). Skip if this node is already tight on
#      VRAM: the LLM plus a second GPU model competes for the same card.
#      You can add/remove a voice pod on a node later from miniaicloud's
#      admin panel without re-running this installer, once that
#      remote-control piece (a later phase of this project) exists.
#   5. Registers with the relay, choosing the network path automatically:
#      - Normal box: installs Tailscale, exchanges the enrollment token for
#        a join key via POST /api/nodes/enroll, runs `tailscale up --ssh`,
#        then reports its tailnet IP via POST /api/nodes/register — enabled
#        immediately, no manual admin-approval step. The admin can then SSH
#        straight to it from anywhere, and lock it out (disable + remove
#        from the tailnet in one action) from miniaicloud's Backends page.
#      - RunPod pod (detected via $RUNPOD_POD_ID): skips Tailscale entirely
#        — pods have no /dev/net/tun access, so tailscaled can't do inbound
#        reachability there — and registers directly with the pod's own
#        RunPod proxy URL instead. SSH access for these nodes is RunPod's
#        own (dashboard/CLI), not Tailscale SSH.
#   6. Asks whether to enable HuggingFace model support (skipped on RunPod —
#      see the section itself for why). If yes: clones miniclosedai-node
#      (for its manager/ control plane + the mcai-node CLI), sets up the
#      manager's lightweight venv, sets up the bare-metal transformers shim
#      engine (the one that reliably works with no Docker/vLLM setup),
#      optionally saves a HuggingFace token, and runs the manager as a
#      systemd service (or a background process if systemd isn't present).
#      `mcai-node run <hf_id>` then downloads + serves any HF model; a
#      launched model registers as a SECOND backend under this same node
#      via `mcai-node register`, alongside its Ollama backend.
#
# Env vars (all optional except the token, which the script will prompt for
# if not set):
#   MINICLOSEDAI_HUB_URL      miniaicloud base URL (default: https://app.interdataresearch.ai)
#   MINICLOSEDAI_NODE_TOKEN   enrollment token — skips the interactive prompt
#   MINICLOSEDAI_NODE_NAME    this node's name on the network (default: hostname)
#   MINICLOSEDAI_NODE_VOICE   1/0 — install a local Latina voice pod (skips the prompt)
#   OLLAMA_MODEL              model to pull (default: qwen3.5:4b)
#   OLLAMA_PORT               port Ollama listens on (default: 11434)
#   OLLAMA_CONTEXT_LENGTH     context window, in tokens (default: 32768)
#   LATINA_DIR                where to clone latinavoicepod (default: $HOME/latinavoicepod)
#   ASK_REPO                  edstui repo to pipx-install (default: git+https://github.com/edantonio505/edstui.git)
#   MINICLOSEDAI_NODE_ASK_API_KEY  relay API key so `ask` reaches interdata directly (skips the prompt; blank = skip entirely)
#   MINICLOSEDAI_NODE_ASK_MODEL    model `ask` asks the relay for (default: qwen3.8:latest)
#   MINICLOSEDAI_NODE_HF      1/0 — enable HuggingFace model support (skips the prompt)
#   MINICLOSEDAI_NODE_HF_TOKEN  HuggingFace access token to save (skips the prompt)
#   MINICLOSEDAI_NODE_REPO_DIR  where to clone miniclosedai-node itself (default: $HOME/miniclosedai-node)
#   MINICLOSEDAI_NODE_HOME    where mcai-node keeps its local state (default: $HOME/.miniclosedai-node)

set -euo pipefail

HUB_URL="${MINICLOSEDAI_HUB_URL:-https://app.interdataresearch.ai}"
NODE_NAME="${MINICLOSEDAI_NODE_NAME:-$(hostname)}"
# qwen3.5:4b (~3.4GB weights), not the 9b variant (~6.6GB weights alone —
# already over a 6GB VRAM budget before adding any context/overhead). Real,
# measured total footprint at OLLAMA_CONTEXT_LENGTH below: ~4.4GB, leaving
# real headroom on an 8GB card instead of running it right at the edge.
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.5:4b}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
# Ollama auto-picks a context length by detected VRAM (<24GiB -> 4096,
# 24-48GiB -> 32768, 48GiB+ -> the model's full native context) unless told
# otherwise — so left unset, an 8GB card would silently land on a cramped
# 4096 tokens. Set explicitly instead: both self-documenting, and immune to
# Ollama changing that heuristic or misdetecting VRAM later. 32768 costs
# ~1GB of KV cache on top of the model's weights (this architecture caches
# K/V on only 1-in-4 layers) — comfortably inside a 6GB budget with qwen3.5:4b.
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-32768}"
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

SUDO=""; [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

# Best-effort auto-install for tools this script (or something it shells
# out to) assumes exist but that aren't guaranteed present on a fresh box —
# apt first (sidesteps needing to know the right brew formula/package name
# case by case), brew as a macOS fallback, warn-not-fail either way, since
# none of these should block the node's actual registration.
ensure_tool() {
    local bin="$1" apt_pkg="$2" brew_pkg="$3" why="$4"
    command -v "$bin" >/dev/null 2>&1 && return 0
    say "Installing $apt_pkg ($why)…"
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "$apt_pkg"
    elif command -v brew >/dev/null 2>&1; then
        brew install "$brew_pkg"
    fi
    command -v "$bin" >/dev/null 2>&1 \
        && ok "$apt_pkg installed" \
        || warn "couldn't install $apt_pkg automatically — install it manually, then re-run"
}
# `git` isn't a dependency of the `pipx` apt package, and `pipx install
# git+https://...` needs it on PATH just to clone the repo — without it,
# the `ask` (edstui) install step below fails silently on any box that
# doesn't already happen to have git (this dev machine always has, which is
# why this went uncaught here).
ensure_tool git git git "required by pipx to install the \`ask\` CLI from GitHub"
# Ollama's own official installer extracts a .tar.zst archive and hard-fails
# with "This version requires zstd for extraction" if it's missing — not
# guaranteed present either (surfaced on arm64 while building this script's
# own Docker test harness; the same class of "assumed present" gap as git).
ensure_tool zstd zstd zstd "required by Ollama's own installer to extract its release archive"

# `curl ... | bash` (the documented one-liner) feeds this whole script in on
# stdin, so a plain `read` here would immediately hit EOF instead of
# prompting. Read from the controlling terminal directly instead — works
# even with stdin occupied, as long as one is actually attached.
# `[ -r /dev/tty ]` alone isn't enough: the device node can exist and pass a
# stat-based permission check while actually opening it still fails with
# ENXIO ("No such device or address") — real in a `docker exec` with no
# allocated pty, which under `set -e` would otherwise kill the whole script
# the first time a prompt is reached with nothing piped in for it. Test by
# actually attempting to open it, inside an `if` condition (exempt from
# `set -e`), rather than trusting the permission bits.
prompt() {
    if { : > /dev/tty; } 2>/dev/null; then
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

# Ollama binds 127.0.0.1 only by default — invisible to the relay over
# Tailscale no matter how well the tailnet itself is configured (this is
# exactly what made real nodes land "ejected": tailnet reachable, port
# refused). Force it onto all interfaces unconditionally — not just on a
# fresh install, since Ollama may already have been present with its
# systemd unit's default binding, outside this script's control — and then
# ACTUALLY VERIFY the bind took, rather than trusting that `systemctl
# restart` succeeding means the override applied. Repeated real installs
# hit exactly this trap: a previous partial run left a plausible-looking
# override.conf on disk with the daemon never actually reloaded/restarted
# against it, so a "does the file already look right, skip re-applying"
# shortcut would have kept re-registering a still-broken node every time.
# Real check of what's actually bound, not what's configured — a unit's
# Environment can be correct while a stray, non-systemd `ollama serve`
# process from an earlier attempt (e.g. this script's own fallback further
# down, left running from a previous partial/interrupted run) still holds
# the port on 127.0.0.1. systemd then fails to rebind 0.0.0.0 (address
# already in use) while `systemctl restart` still reports success and the
# unit's configured Environment still looks correct — the exact trap that
# made `systemctl show -p Environment` alone an unreliable signal.
ollama_bound_to_all_interfaces() {
    command -v ss >/dev/null 2>&1 || return 0  # can't check — assume fine
    local bound
    bound="$(ss -ltn "sport = :${OLLAMA_PORT}" 2>/dev/null | tail -n +2)"
    case "$bound" in
        *"0.0.0.0:${OLLAMA_PORT}"*|*"*:${OLLAMA_PORT}"*|*":::${OLLAMA_PORT}"*) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_ollama_listens_on_all_interfaces() {
    # Alongside the bind fix: OLLAMA_KEEP_ALIVE=-1 (Ollama unloads an idle
    # model after 5 minutes by default, which would mean the first request
    # to this node after any quiet period pays a multi-second cold-load
    # penalty — bad for a node meant to answer relay traffic on demand), and
    # OLLAMA_CONTEXT_LENGTH set explicitly rather than left to Ollama's own
    # VRAM-tiered auto-default (see the OLLAMA_CONTEXT_LENGTH comment above).
    if command -v systemctl >/dev/null 2>&1 \
        && [ "$(systemctl show -p LoadState --value ollama.service 2>/dev/null)" = "loaded" ]; then
        local override_dir=/etc/systemd/system/ollama.service.d
        say "Configuring Ollama to listen on all interfaces, keep the model loaded forever, and use a ${OLLAMA_CONTEXT_LENGTH}-token context…"
        $SUDO mkdir -p "$override_dir"
        printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0:%s"\nEnvironment="OLLAMA_KEEP_ALIVE=-1"\nEnvironment="OLLAMA_CONTEXT_LENGTH=%s"\n' \
            "$OLLAMA_PORT" "$OLLAMA_CONTEXT_LENGTH" | $SUDO tee "$override_dir/override.conf" >/dev/null
        $SUDO systemctl daemon-reload
        $SUDO systemctl restart ollama
        sleep 1

        if ! ollama_bound_to_all_interfaces; then
            # Restart "succeeded" but the port is still held by loopback-only
            # — almost always a stray process outside systemd's control.
            # Find and stop whatever's actually holding the port, then retry
            # once before giving up with real diagnostics.
            say "Still bound to loopback after restart — checking for a stray process holding the port…"
            STRAY_PID="$($SUDO ss -ltnp "sport = :${OLLAMA_PORT}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)"
            if [ -n "${STRAY_PID:-}" ]; then
                say "Stopping stray process (pid $STRAY_PID) and restarting Ollama…"
                $SUDO kill "$STRAY_PID" 2>/dev/null || true
                sleep 1
                $SUDO systemctl restart ollama
                sleep 1
            fi
        fi

        if ! ollama_bound_to_all_interfaces; then
            local active
            active="$(systemctl is-active ollama.service 2>/dev/null || true)"
            fail "Ollama still isn't listening on 0.0.0.0:${OLLAMA_PORT} after a clean restart (service is '${active:-unknown}'). Its configured Environment can look correct even when the process itself failed to (re)bind — check the real error with: sudo journalctl -u ollama -n 30 --no-pager"
        fi
        ok "Ollama confirmed listening on all interfaces (:${OLLAMA_PORT})"
    else
        # No systemd-managed ollama.service (macOS, a non-systemd Linux, or
        # Ollama running some other way entirely) — best effort: export for
        # this script's own fallback `ollama serve` below. If Ollama is
        # already running as its own app/service outside this script, it
        # needs OLLAMA_HOST set and a manual restart for this to take effect.
        export OLLAMA_HOST="0.0.0.0:${OLLAMA_PORT}"
        export OLLAMA_KEEP_ALIVE=-1
        export OLLAMA_CONTEXT_LENGTH
        warn "No systemd-managed ollama.service found — if Ollama is already running some other way, set OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}, OLLAMA_KEEP_ALIVE=-1, and OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}, then restart it manually."
    fi
}
ensure_ollama_listens_on_all_interfaces

# Make sure something is actually listening before we try to pull.
if ! curl -sf -m 2 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1; then
    say "Starting Ollama…"
    OLLAMA_HOST="0.0.0.0:${OLLAMA_PORT}" OLLAMA_KEEP_ALIVE=-1 OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH}" \
        nohup ollama serve >/tmp/miniclosedai-node-ollama.log 2>&1 &
    disown
    for _ in $(seq 1 20); do
        sleep 0.5
        curl -sf -m 2 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1 && break
    done
fi
curl -sf -m 2 "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1 \
    || fail "Ollama isn't answering on :${OLLAMA_PORT} — check /tmp/miniclosedai-node-ollama.log"

# The check above only proves localhost reachability — 127.0.0.1-only
# binding would pass it too. Confirm the listening socket itself is on all
# interfaces before ever proceeding — this covers the non-systemd fallback
# path just above; the systemd path already verified this for real inside
# ensure_ollama_listens_on_all_interfaces.
ollama_bound_to_all_interfaces \
    || fail "Ollama is not listening on all interfaces — the relay would not be able to reach this node. Refusing to register a backend that's known to be broken."

say "Pulling ${OLLAMA_MODEL} (comfortably under a 6GB VRAM budget with room to spare)…"
ollama pull "$OLLAMA_MODEL"
ok "model ready: $OLLAMA_MODEL"

# Explicitly load the model into memory now, with an indefinite keep_alive,
# instead of waiting for the first real inference request to pay the
# multi-second cold-load cost. Omitting "prompt" is Ollama's documented way
# to load (or, with keep_alive:0, unload) a model without generating a
# completion — nothing is sent to the model, this only warms it into VRAM.
say "Loading ${OLLAMA_MODEL} into memory (keep_alive: forever)…"
curl -sf -m 120 -X POST "http://127.0.0.1:${OLLAMA_PORT}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${OLLAMA_MODEL}\",\"keep_alive\":-1}" >/dev/null \
    || warn "couldn't pre-load ${OLLAMA_MODEL} — it will still load on its first real request, just with a one-time delay"
if ollama ps 2>/dev/null | grep -qF "$OLLAMA_MODEL"; then
    ok "model loaded and resident (will not unload)"
else
    warn "model doesn't show as loaded in 'ollama ps' — check 'sudo journalctl -u ollama -n 30 --no-pager' if the node responds slowly to its first request"
fi

# ---------- 3. ask (edstui) ----------
# Installed here, before network registration, so a node still ends up with
# `ask` even if Tailscale/registration fails further down — this used to
# run last, so a registration hiccup meant the script never reached it at
# all, compounding the very problem `ask` would help debug.
# `pip install --user pipx` alone fails outright on modern Debian/Ubuntu
# (PEP 668 "externally managed environment") unless --break-system-packages
# is passed or apt is used instead — and a bare `|| warn` here would swallow
# that failure silently, so pipx (and therefore `ask`) would never actually
# get installed. Try apt first (Debian/Ubuntu's own recommended path,
# sidesteps PEP 668 entirely), then pip with the override flag, then plain
# pip for older systems that predate PEP 668 altogether.
if ! command -v pipx >/dev/null 2>&1; then
    say "Installing pipx (for the \`ask\` CLI)…"
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq pipx
    fi
    if ! command -v pipx >/dev/null 2>&1; then
        python3 -m pip install -q --user pipx --break-system-packages 2>/dev/null \
            || python3 -m pip install -q --user pipx
    fi
    python3 -m pipx ensurepath >/dev/null 2>&1 || true
    export PATH="$HOME/.local/bin:$PATH"
fi
if command -v pipx >/dev/null 2>&1; then
    say "Installing the \`ask\` CLI (edstui)…"
    pipx install --quiet --force "$ASK_REPO" && ok "ask CLI ready — run \`ask\` from any shell" \
        || warn "pipx install of $ASK_REPO failed (network?) — re-run later: pipx install --force $ASK_REPO"
else
    warn "pipx still isn't installed after apt/pip attempts — \`ask\` was skipped. Install pipx manually, then: pipx install --force $ASK_REPO"
fi

# `ask` talks to whatever Ollama-shaped host EDS_TUI_URL points at using
# Ollama's own native wire protocol (not this node's OpenAI-compatible
# surfaces) — miniaicloud (the relay) exposes exactly that natively at
# $HUB_URL/api/{tags,chat,...}, gated by a genuine relay API key (an ApiKey
# tied to a user, NOT this node's own node_api_key — a completely separate
# credential/table, so the node's registration secret can't be reused here).
# Pointing `ask` there instead of at this node's own small model is what lets
# it reach the wider interdata network, e.g. qwen3.8:latest if that's what's
# registered there — not just whatever this one node happens to be running.
if command -v ask >/dev/null 2>&1 || command -v pipx >/dev/null 2>&1; then
    if [ -n "${MINICLOSEDAI_NODE_ASK_API_KEY:-}" ]; then
        ASK_API_KEY="$MINICLOSEDAI_NODE_ASK_API_KEY"
    else
        prompt 'Interdata relay API key for `ask` (optional — lets `ask` reach the whole network, not just this node; mint one in miniaicloud admin -> API keys; blank to skip): '
        ASK_API_KEY="$REPLY"
    fi
    if [ -n "$ASK_API_KEY" ]; then
        BASH_ALIASES_FILE="$HOME/.bash_aliases"
        touch "$BASH_ALIASES_FILE"
        # Idempotent: drop any lines a PRIOR run of this installer added,
        # so re-running doesn't pile up duplicate/stale exports.
        sed -i '/^export EDS_TUI_URL=/d; /^export EDS_TUI_TOKEN=/d; /^export EDS_TUI_MODEL=/d' "$BASH_ALIASES_FILE"
        {
            printf 'export EDS_TUI_URL=%q\n' "$HUB_URL"
            printf 'export EDS_TUI_TOKEN=%q\n' "$ASK_API_KEY"
            printf 'export EDS_TUI_MODEL=%q\n' "${MINICLOSEDAI_NODE_ASK_MODEL:-qwen3.8:latest}"
        } >> "$BASH_ALIASES_FILE"
        ok "ask configured to reach interdata directly — open a new shell (or: source ~/.bash_aliases)"
    else
        say "No relay API key given — ask is installed but not yet pointed at interdata. Configure it later by adding EDS_TUI_URL/EDS_TUI_TOKEN to ~/.bash_aliases (see miniclosedai-node's README)."
    fi
fi

# ---------- 4. Optional local voice pod (Linux only) ----------
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

# Persist this node's interdata-network identity (node_id + node_api_key,
# shown once in /api/nodes/register's response) so mcai-node's own `register`
# command can later add further backends (e.g. a launched HuggingFace model)
# under this SAME node without needing a fresh enrollment token.
NODE_STATE_DIR="${MINICLOSEDAI_NODE_HOME:-$HOME/.miniclosedai-node}"
save_node_state() {
    mkdir -p "$NODE_STATE_DIR"
    printf '%s' "$1" | python3 -c '
import json, sys
r = json.load(sys.stdin)
json.dump({"node_id": r["node_id"], "node_api_key": r["node_api_key"],
           "hub_url": "'"$HUB_URL"'"}, sys.stdout)
' > "$NODE_STATE_DIR/node.json"
    chmod 600 "$NODE_STATE_DIR/node.json"
}

# ---------- 5. Network path: RunPod proxy, or Tailscale ----------
# RunPod sets RUNPOD_POD_ID inside every pod — reliable, no guessing needed
# (the same signal latinavoicepod's own /api/connect-info already keys off
# of). RunPod pods can't use Tailscale for inbound reachability: they have
# no /dev/net/tun access (blocked since runc v1.2), so `tailscaled` either
# refuses to start or falls back to userspace-networking mode, which only
# supports outbound connections — the relay could never connect INTO the
# pod at a tailnet address. A RunPod node instead registers directly with
# its own RunPod proxy URL, skipping Tailscale (and /enroll, which only
# exists to hand out a Tailscale join key) entirely.
if [ -n "${RUNPOD_POD_ID:-}" ]; then
    say "RunPod pod detected (${RUNPOD_POD_ID}) — using its proxy URL instead of Tailscale."
    NODE_BASE_URL="https://${RUNPOD_POD_ID}-${OLLAMA_PORT}.proxy.runpod.net"

    # Best-effort only, not fatal: a pod curling its own external proxy
    # hostname can hit hairpin-NAT quirks that don't reflect whether the
    # RELAY (a genuinely separate host) can reach it — which is what
    # actually matters. Warn rather than block registration on an
    # inconclusive local test; verify for real from miniaicloud's admin
    # "Test" button after registering.
    say "Best-effort check of ${NODE_BASE_URL} (may be inconclusive from inside the pod itself)…"
    if curl -sf -m 10 "${NODE_BASE_URL}/api/tags" >/dev/null 2>&1; then
        ok "proxy URL answered from inside the pod"
    else
        warn "no answer from inside the pod (common hairpin-NAT false negative) — verify with the Test button on miniaicloud's Backends page after registering"
    fi

    say "Registering with $HUB_URL as an enabled backend…"
    REGISTER_RESP="$(hub_post /api/nodes/register "{\"token\":\"$TOKEN\",\"name\":\"$NODE_NAME\",\"base_url\":\"$NODE_BASE_URL\"}")"
    ok "registered: $REGISTER_RESP"
    save_node_state "$REGISTER_RESP"
    SSH_NOTE="RunPod node — use RunPod's own SSH access (dashboard/CLI), not Tailscale SSH."
else
    if ! command -v tailscale >/dev/null 2>&1; then
        say "Installing Tailscale…"
        if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
            # Homebrew's tailscaled runs as a real launchd system service,
            # unlike the App Store GUI app — the one that actually works headless.
            brew install tailscale
            sudo brew services start tailscale
        else
            curl -fsSL https://tailscale.com/install.sh | sh
        fi
        ok "Tailscale installed"
    else
        ok "Tailscale already installed"
    fi

    say "Requesting a Tailscale join key from $HUB_URL…"
    ENROLL_RESP="$(hub_post /api/nodes/enroll "{\"token\":\"$TOKEN\"}")"
    AUTHKEY="$(printf '%s' "$ENROLL_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tailscale_authkey"])')"
    [ -n "$AUTHKEY" ] || fail "Hub didn't return a Tailscale auth key: $ENROLL_RESP"

    say "Joining the tailnet (this also enables Tailscale SSH — no separate keys to manage)…"
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

    # A host firewall commonly permits loopback but blocks inbound connections
    # on tailscale0 — invisible to both the earlier `ss` bind check and a plain
    # `curl 127.0.0.1` test, but exactly what would leave a node "ejected" even
    # though Ollama is correctly bound to all interfaces. Open it proactively
    # where ufw is in play; best-effort, not fatal if ufw isn't used at all.
    if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "^Status: active"; then
        say "Opening :${OLLAMA_PORT} for the tailscale0 interface (ufw is active)…"
        $SUDO ufw allow in on tailscale0 to any port "$OLLAMA_PORT" proto tcp comment 'miniclosedai-node: relay access' >/dev/null
        ok "ufw rule added for tailscale0:${OLLAMA_PORT}"
    fi

    # The definitive test: curl this node's OWN tailnet address, not loopback
    # — the exact address:port the relay's health probe will use. SSH working
    # is NOT evidence this works: Tailscale SSH is authorized through its own
    # separate `ssh` ACL policy, independent of the general `acls` rules that
    # govern reachability to every other port. Refuse to register a backend
    # with the relay until this has actually been proven over the real path,
    # rather than finding out afterward from miniaicloud's side.
    say "Verifying the node is reachable at its tailnet address (the same path the relay will use)…"
    curl -sf -m 5 "http://${TS_IP}:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1 \
        || fail "Ollama's bind was already confirmed correct (0.0.0.0:${OLLAMA_PORT}, via ss), but $TS_IP:${OLLAMA_PORT} still refuses a connection from this same machine — almost certainly a firewall (ufw/iptables) blocking the tailscale0 interface, not an Ollama config problem. Check 'sudo ufw status' / 'sudo iptables -L -n', allow inbound :${OLLAMA_PORT} on tailscale0, then re-run."
    ok "confirmed reachable at ${TS_IP}:${OLLAMA_PORT} — the same address the relay will probe"

    say "Registering with $HUB_URL as an enabled backend…"
    REGISTER_RESP="$(hub_post /api/nodes/register "{\"token\":\"$TOKEN\",\"name\":\"$NODE_NAME\",\"base_url\":\"http://${TS_IP}:${OLLAMA_PORT}\"}")"
    ok "registered: $REGISTER_RESP"
    save_node_state "$REGISTER_RESP"
    NODE_BASE_URL="http://${TS_IP}:${OLLAMA_PORT}"
    SSH_NOTE="Admin can now SSH in with: tailscale ssh $NODE_NAME"
fi

# ---------- 6. Optional: HuggingFace model support (mcai-node) ----------
# Not offered on a RunPod pod: pods have no systemd (nothing to daemonize
# the manager with) and typically no Docker daemon of their own either
# (nested-container launches would need docker-in-docker or a mounted host
# socket, neither of which a RunPod pod provides) — the one engine left,
# the bare-metal transformers shim, is a reasonable fallback on a normal
# box but not a solid default for RunPod's already-containerized model.
if [ -z "${RUNPOD_POD_ID:-}" ]; then
    if [ -n "${MINICLOSEDAI_NODE_HF:-}" ]; then
        WANT_HF="$MINICLOSEDAI_NODE_HF"
    else
        WANT_HF=0
        prompt 'Enable HuggingFace model support on this node (download + run arbitrary HF models via mcai-node)? [y/N] '
        case "$REPLY" in [Yy]*) WANT_HF=1 ;; esac
    fi

    if [ "$WANT_HF" = "1" ]; then
        NODE_REPO_DIR="${MINICLOSEDAI_NODE_REPO_DIR:-$HOME/miniclosedai-node}"
        if [ -d "$NODE_REPO_DIR/.git" ]; then
            say "miniclosedai-node: existing checkout — pulling"
            git -C "$NODE_REPO_DIR" pull --quiet
        else
            say "Cloning miniclosedai-node (for the model manager + mcai-node CLI)…"
            git clone --quiet https://github.com/edantonio505/miniclosedai-node.git "$NODE_REPO_DIR"
        fi
        MANAGER_DIR="$NODE_REPO_DIR/manager"

        say "Setting up the model manager's control-plane env (lightweight — no torch/vLLM here)…"
        python3 -m venv "$MANAGER_DIR/.venv"
        "$MANAGER_DIR/.venv/bin/pip" install -q -r "$MANAGER_DIR/requirements.txt"
        ok "manager control plane ready"

        # PUBLIC_HOST tells the manager to advertise the SAME tailnet address
        # its Ollama backend already registered with — the address the relay
        # can actually reach — instead of the manager's own LAN-IP guess.
        printf 'PUBLIC_HOST=%s\n' "$TS_IP" > "$MANAGER_DIR/.env"

        if [ -n "${MINICLOSEDAI_NODE_HF_TOKEN:-}" ]; then
            printf 'HF_TOKEN=%s\n' "$MINICLOSEDAI_NODE_HF_TOKEN" >> "$MANAGER_DIR/.env"
        else
            prompt 'HuggingFace access token (optional, only needed for gated models — blank to skip): '
            [ -n "$REPLY" ] && printf 'HF_TOKEN=%s\n' "$REPLY" >> "$MANAGER_DIR/.env"
        fi

        # The shim (bare-metal transformers) is the engine that reliably works
        # on a plain gaming PC with no Docker daemon and no pip-installed
        # vLLM — set it up now so `mcai-node run` works immediately rather
        # than needing a separate manual step. Best-effort: a slow/failed
        # torch install here shouldn't fail the whole install — Ollama
        # registration above already succeeded, which is the critical path.
        say "Setting up the transformers shim engine (downloads torch — can take a few minutes)…"
        ( cd "$MANAGER_DIR" && ./setup_shim.sh >/tmp/miniclosedai-node-shim-setup.log 2>&1 ) \
            && ok "shim engine ready" \
            || warn "shim setup didn't finish cleanly — check /tmp/miniclosedai-node-shim-setup.log. Docker (if installed) or a manual 'pip install vllm' still work as alternate engines."

        say "Installing the mcai-node CLI…"
        MCAI_NODE_BIN="/usr/local/bin/mcai-node"
        if ! $SUDO cp "$NODE_REPO_DIR/mcai-node" "$MCAI_NODE_BIN" 2>/dev/null; then
            mkdir -p "$HOME/.local/bin"
            cp "$NODE_REPO_DIR/mcai-node" "$HOME/.local/bin/mcai-node"
            MCAI_NODE_BIN="$HOME/.local/bin/mcai-node"
            export PATH="$HOME/.local/bin:$PATH"
        fi
        chmod +x "$MCAI_NODE_BIN"
        ok "mcai-node installed: $MCAI_NODE_BIN"

        say "Starting the model manager…"
        if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" = "0" -o -n "$SUDO" ]; then
            $SUDO tee /etc/systemd/system/miniclosedai-node-manager.service >/dev/null <<EOF
[Unit]
Description=miniclosedai-node HuggingFace model manager
After=network.target

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$MANAGER_DIR
EnvironmentFile=$MANAGER_DIR/.env
ExecStart=$MANAGER_DIR/.venv/bin/python $MANAGER_DIR/app.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
            $SUDO systemctl daemon-reload
            $SUDO systemctl enable --now miniclosedai-node-manager
            sleep 1
            if systemctl is-active --quiet miniclosedai-node-manager; then
                ok "model manager running as a systemd service (survives reboot)"
            else
                warn "manager service didn't come up cleanly — check: sudo journalctl -u miniclosedai-node-manager -n 30 --no-pager"
            fi
        else
            # Absolute paths, deliberately — a relative "app.py" would show up
            # in `ps`/`pkill -f` as just that (the cwd isn't visible there),
            # which is both hard to target precisely later and exactly what
            # broke uninstall.sh's own `pkill -f "$MANAGER_DIR/app.py"` cleanup
            # when this was first tested.
            ( cd "$MANAGER_DIR" && set -a && . ./.env && set +a && \
              nohup "$MANAGER_DIR/.venv/bin/python" "$MANAGER_DIR/app.py" \
                  >/tmp/miniclosedai-node-manager.log 2>&1 & disown )
            warn "no systemd here — started the manager in the background, but it will NOT survive a reboot. Log: /tmp/miniclosedai-node-manager.log"
        fi

        say "  next: mcai-node run <hf_id>   (then: mcai-node register <id> to add it to the network)"
    fi
fi

echo
printf '%s%s✓ Node enrolled on the interdata network%s\n' "$BOLD" "$GREEN" "$RST"
printf '  address: %s   model: %s\n' "$NODE_BASE_URL" "$OLLAMA_MODEL"
printf '  %s\n' "$SSH_NOTE"
