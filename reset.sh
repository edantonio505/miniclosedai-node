#!/usr/bin/env bash
# miniclosedai-node/reset.sh — undo a prior install's network/binding state
# on THIS machine so install.sh can run against a genuinely clean slate.
#
# Repeated installer runs on the same already-configured box are hard to
# diagnose: a stale Tailscale device identity, a leftover systemd override,
# or a stray orphaned `ollama serve` process from an earlier attempt can all
# make a fresh install.sh run behave unpredictably. This undoes exactly
# those three things — nothing else.
#
# Does NOT remove Ollama itself, any pulled models, `ask`, or a local
# latinavoicepod install — only the parts that make repeated testing on the
# same box unreliable.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/edantonio505/miniclosedai-node/main/reset.sh | bash
#   ./install.sh    # (or the one-liner) — now a genuinely fresh attempt
#
# There's no self-deregister endpoint yet, so this machine's OLD backend row
# is still sitting in miniaicloud after this runs — delete it from the
# admin Backends page so a fresh install.sh doesn't leave a confusing stale
# duplicate next to the new one.

set -euo pipefail

OLLAMA_PORT="${OLLAMA_PORT:-11434}"

if [ -t 1 ]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=''; RED=''; RST=''; fi
say()  { printf '%s\n' "$1"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RST" "$1"; }
warn() { printf '%s!%s %s\n' "$RED" "$RST" "$1" >&2; }

SUDO=""; [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

say "Resetting this node's Tailscale identity and Ollama bind override…"

if command -v tailscale >/dev/null 2>&1; then
    # `down` disconnects; `logout` also clears the local node key and drops
    # this device from the tailnet's device list entirely — re-enrolling
    # afterward gets a genuinely new device identity rather than
    # re-authenticating the same stale one (which can retain its old
    # tag/hostname registration).
    $SUDO tailscale down 2>/dev/null || true
    $SUDO tailscale logout 2>/dev/null || true
    ok "left the tailnet (tailscale down + logout)"
else
    say "Tailscale isn't installed here — nothing to leave."
fi

if [ -f /etc/systemd/system/ollama.service.d/override.conf ]; then
    $SUDO rm -f /etc/systemd/system/ollama.service.d/override.conf
    $SUDO systemctl daemon-reload 2>/dev/null || true
    $SUDO systemctl restart ollama 2>/dev/null || true
    ok "removed the Ollama bind override (back to its own default)"
else
    say "No Ollama bind override found — nothing to remove."
fi

# A stray, non-systemd `ollama serve` (e.g. left running from an earlier
# partial/interrupted install.sh run) can hold the port even after the
# systemd unit above is back to a clean state — only touch it if the
# systemd-managed service isn't the one actually holding the port.
if command -v ss >/dev/null 2>&1 && ! systemctl is-active --quiet ollama 2>/dev/null; then
    STRAY_PID="$($SUDO ss -ltnp "sport = :${OLLAMA_PORT}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
    if [ -n "${STRAY_PID:-}" ]; then
        $SUDO kill "$STRAY_PID" 2>/dev/null || true
        ok "stopped a stray (non-systemd) ollama process (pid $STRAY_PID)"
    fi
fi

echo
ok "Reset complete."
say "Delete this machine's old backend row from miniaicloud's admin Backends page,"
say "then run install.sh fresh:"
say "  curl -fsSL https://raw.githubusercontent.com/edantonio505/miniclosedai-node/main/install.sh | bash"
