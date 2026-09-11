#!/usr/bin/env bash
# miniclosedai-node/uninstall.sh — remove everything install.sh set up on
# THIS machine. Unlike reset.sh (which only undoes network/binding state so
# a dirty test box can re-enroll cleanly, deliberately leaving software
# installed), this actually uninstalls it: Ollama (+ its systemd override
# and, with confirmation, its pulled models), Tailscale (+ leaving the
# tailnet), the `ask` CLI (eds-tui, npm package `eds-tui` — or, from a
# prior version of install.sh, the same pipx-installed Python package), a
# local
# latinavoicepod checkout if one exists, and — if HuggingFace model support
# was enabled — the model manager service, its cloned repo, and the
# mcai-node CLI.
#
# There's no `mcai-node uninstall` subcommand for this to be part of yet (its
# own repo is one of the things this script may be removing) — ships for now
# as a standalone script, same pattern as install.sh/reset.sh.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/edantonio505/miniclosedai-node/main/uninstall.sh | bash
#
# Env vars (all optional):
#   MINICLOSEDAI_UNINSTALL_MODELS   1/0 — delete pulled Ollama models too (skips the confirmation prompt)
#   LATINA_DIR                      where latinavoicepod was cloned (default: $HOME/latinavoicepod)
#   OLLAMA_PORT                     port Ollama listens on (default: 11434)
#   MINICLOSEDAI_NODE_REPO_DIR      where miniclosedai-node was cloned for HF support (default: $HOME/miniclosedai-node)
#   MINICLOSEDAI_NODE_HOME          where mcai-node's local state lives (default: $HOME/.miniclosedai-node)

set -euo pipefail

OLLAMA_PORT="${OLLAMA_PORT:-11434}"
LATINA_DIR="${LATINA_DIR:-$HOME/latinavoicepod}"
NODE_REPO_DIR="${MINICLOSEDAI_NODE_REPO_DIR:-$HOME/miniclosedai-node}"
NODE_STATE_DIR="${MINICLOSEDAI_NODE_HOME:-$HOME/.miniclosedai-node}"

if [ -t 1 ]; then
    BOLD=$'\e[1m'; GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; RST=$'\e[0m'
else
    BOLD=''; GREEN=''; RED=''; DIM=''; RST=''
fi
say()  { printf '%s\n' "$1"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RST" "$1"; }
warn() { printf '%s!%s %s\n' "$RED"   "$RST" "$1" >&2; }

OS="$(uname -s)"
SUDO=""; [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

# Same /dev/tty trick as install.sh — `curl ... | bash` occupies stdin, so a
# plain `read` here would hit EOF immediately instead of prompting.
prompt() {
    if [ -r /dev/tty ]; then
        printf '%s' "$1" > /dev/tty
        read -r REPLY < /dev/tty
    else
        REPLY=""
    fi
}

printf '%sminiclosedai-node uninstaller%s\n' "$BOLD" "$RST"
echo

# ---------- 1. ask (eds-tui) ----------
# Checks both npm (the current install method) and pipx (what a node
# enrolled via an older install.sh would have used) — a node may have
# either, and this should clean up whichever is actually present.
REMOVED_ASK=0
if command -v npm >/dev/null 2>&1 && npm list -g eds-tui --depth=0 >/dev/null 2>&1; then
    say "Removing the ask CLI (npm package eds-tui)…"
    npm uninstall -g eds-tui >/dev/null 2>&1 && { ok "ask CLI removed"; REMOVED_ASK=1; } \
        || warn "npm uninstall -g eds-tui failed — remove manually"
fi
if command -v pipx >/dev/null 2>&1 && pipx list --short 2>/dev/null | grep -q '^eds-tui '; then
    say "Removing the ask CLI (old pipx package eds-tui, from a prior install)…"
    pipx uninstall eds-tui >/dev/null 2>&1 && { ok "ask CLI (pipx) removed"; REMOVED_ASK=1; } \
        || warn "pipx uninstall eds-tui failed — remove manually"
fi
if [ "$REMOVED_ASK" = "0" ]; then
    say "ask CLI not installed (checked npm and pipx) — nothing to remove."
fi

# ---------- 2. Ollama ----------
if command -v ollama >/dev/null 2>&1; then
    if [ -n "${MINICLOSEDAI_UNINSTALL_MODELS:-}" ]; then
        WANT_DELETE_MODELS="$MINICLOSEDAI_UNINSTALL_MODELS"
    else
        prompt 'Also delete pulled Ollama models (frees disk, re-downloads next install)? [y/N] '
        WANT_DELETE_MODELS=0
        case "$REPLY" in [Yy]*) WANT_DELETE_MODELS=1 ;; esac
    fi

    if command -v systemctl >/dev/null 2>&1 \
        && [ "$(systemctl show -p LoadState --value ollama.service 2>/dev/null)" = "loaded" ]; then
        say "Stopping and removing the Ollama systemd service…"
        $SUDO systemctl stop ollama 2>/dev/null || true
        $SUDO systemctl disable ollama 2>/dev/null || true
        $SUDO rm -rf /etc/systemd/system/ollama.service.d
        $SUDO systemctl daemon-reload 2>/dev/null || true
        ok "Ollama service stopped and its bind override removed"
    else
        # No systemd unit — this machine's Ollama was started as install.sh's
        # own fallback `nohup ollama serve`, or as a separate app entirely.
        pkill -f 'ollama serve' 2>/dev/null || true
    fi

    if [ "$WANT_DELETE_MODELS" = "1" ]; then
        say "Deleting pulled model weights…"
        $SUDO rm -rf "$HOME/.ollama/models" /usr/share/ollama/.ollama/models 2>/dev/null || true
        ok "model weights deleted"
    else
        say "Leaving pulled model weights in place (~/.ollama/models)."
    fi

    if [ "$OS" = "Linux" ] && command -v apt-get >/dev/null 2>&1 && dpkg -l ollama >/dev/null 2>&1; then
        $SUDO apt-get remove -y -qq ollama >/dev/null 2>&1 || true
    fi
    # The official install.sh installs to /usr/local/bin (or /usr/bin) rather
    # than via apt on most systems — remove the binary directly too.
    $SUDO rm -f /usr/local/bin/ollama /usr/bin/ollama 2>/dev/null || true
    hash -r 2>/dev/null || true  # clear bash's PATH cache — a removed binary can otherwise still show as found
    if command -v ollama >/dev/null 2>&1; then
        warn "ollama binary still on PATH somewhere — remove it manually if you want it fully gone"
    else
        ok "Ollama uninstalled"
    fi
else
    say "Ollama not installed — nothing to remove."
fi

# ---------- 3. latinavoicepod (if installed) ----------
if [ -d "$LATINA_DIR" ]; then
    say "Stopping and removing latinavoicepod ($LATINA_DIR)…"
    pkill -f "$LATINA_DIR" 2>/dev/null || true
    rm -rf "$LATINA_DIR"
    ok "latinavoicepod removed"
else
    say "No local latinavoicepod checkout found — nothing to remove."
fi

# ---------- 4. Tailscale ----------
if command -v tailscale >/dev/null 2>&1; then
    say "Leaving the tailnet and removing Tailscale…"
    $SUDO tailscale down 2>/dev/null || true
    $SUDO tailscale logout 2>/dev/null || true
    if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
        $SUDO brew services stop tailscale 2>/dev/null || true
        brew uninstall tailscale 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        $SUDO systemctl stop tailscaled 2>/dev/null || true
        $SUDO apt-get remove -y -qq tailscale >/dev/null 2>&1 || true
    fi
    hash -r 2>/dev/null || true  # clear bash's PATH cache — a removed binary can otherwise still show as found
    if command -v tailscale >/dev/null 2>&1; then
        warn "tailscale binary still on PATH somewhere — remove it manually if you want it fully gone"
    else
        ok "Tailscale removed"
    fi
else
    say "Tailscale not installed — nothing to remove."
fi

# ---------- 5. HuggingFace model manager (if enabled) ----------
if command -v systemctl >/dev/null 2>&1 \
    && systemctl list-unit-files miniclosedai-node-manager.service >/dev/null 2>&1; then
    say "Stopping and removing the model manager service…"
    $SUDO systemctl disable --now miniclosedai-node-manager >/dev/null 2>&1 || true
    $SUDO rm -f /etc/systemd/system/miniclosedai-node-manager.service
    $SUDO systemctl daemon-reload 2>/dev/null || true
    ok "model manager service removed"
else
    pkill -f "$NODE_REPO_DIR/manager/app.py" 2>/dev/null || true
fi

$SUDO rm -f /usr/local/bin/mcai-node
rm -f "$HOME/.local/bin/mcai-node"
hash -r 2>/dev/null || true
if command -v mcai-node >/dev/null 2>&1; then
    warn "mcai-node still on PATH somewhere — remove it manually if you want it fully gone"
fi

if [ -d "$NODE_REPO_DIR" ]; then
    say "Removing $NODE_REPO_DIR (manager + downloaded torch venv)…"
    rm -rf "$NODE_REPO_DIR"
    ok "miniclosedai-node checkout removed"
else
    say "No miniclosedai-node checkout found — HuggingFace support wasn't enabled."
fi

if [ -d "$NODE_STATE_DIR" ]; then
    rm -rf "$NODE_STATE_DIR"
    ok "removed local node state ($NODE_STATE_DIR)"
fi

echo
ok "Uninstall complete."
say "There's still no self-deregister endpoint — delete this machine's backend"
say "row(s) from miniaicloud's admin Backends page so it doesn't linger there"
say "showing as ejected."
