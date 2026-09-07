# miniclosedai-node

A one-command installer that turns a spare GPU box — the reference target
is an 8GB-VRAM Linux or Windows gaming PC — into a compute (and optionally
voice) node on the **interdata network**, run by [miniaicloud](https://github.com/edantonio505/interdatarcomputationrelay)
(`app.interdataresearch.ai`).

This is deliberately not "real miniclosedai": no chat UI, no functions, no
local history. A node is a compute/voice contributor plus an
[`ask`](https://github.com/edantonio505/edstui)-connected terminal — leaving
as much of a small card's VRAM as possible for the model itself.

## What one install does

1. Takes an **enrollment token**, minted ahead of time by an admin in
   miniaicloud's admin panel (Node tokens page). The token is the trust
   gate — no separate manual approval step per node.
2. Installs **Ollama** and pulls `qwen3.5:9b-q4_K_M` (6.6GB — fits an 8GB
   card with headroom; the bare `qwen3.5:9b` tag and the `q8_0` variant, at
   11GB, do not).
3. *(Linux only)* Optionally installs a local **Latina voice pod**
   ([latinavoicepod](https://github.com/edantonio505/latinavoicepod)) —
   asked interactively, since it competes with the LLM for the same VRAM.
4. Installs **Tailscale**, exchanges the enrollment token for a join key via
   miniaicloud's `POST /api/nodes/enroll`, joins with Tailscale's own SSH
   feature enabled (`tailscale up --ssh`) — no separate SSH keypair to
   generate or distribute — then reports this node's tailnet IP back via
   `POST /api/nodes/register` to become an **enabled** backend on the
   network immediately.
5. Installs the **`ask`** CLI ([edstui](https://github.com/edantonio505/edstui))
   via pipx.

Once enrolled, the admin can SSH straight to the node from anywhere
(`tailscale ssh <node-name>`), and lock it out — disabling it and removing
it from the tailnet in one action — from miniaicloud's Backends page.

## Install

**Linux / macOS:**
```bash
curl -fsSL https://raw.githubusercontent.com/edantonio505/miniclosedai-node/main/install.sh | bash
```

**Windows** (elevated PowerShell — `#Requires -RunAsAdministrator` isn't
enforced through `irm | iex`, so the script checks for elevation itself and
fails clearly if you're not running as Administrator):
```powershell
irm https://raw.githubusercontent.com/edantonio505/miniclosedai-node/main/install.ps1 | iex
```

Either way you'll be prompted for the enrollment token, unless
`MINICLOSEDAI_NODE_TOKEN` (or `$env:MINICLOSEDAI_NODE_TOKEN` on Windows) is
already set — useful for a non-interactive/scripted install.

## Env vars

| Var | Default | Notes |
|---|---|---|
| `MINICLOSEDAI_HUB_URL` | `https://app.interdataresearch.ai` | miniaicloud base URL |
| `MINICLOSEDAI_NODE_TOKEN` | *(prompts)* | enrollment token from the admin panel |
| `MINICLOSEDAI_NODE_NAME` | hostname | this node's name on the network and its Tailscale hostname |
| `MINICLOSEDAI_NODE_VOICE` | *(prompts, Linux only)* | `1`/`0` — install a local Latina voice pod |
| `OLLAMA_MODEL` | `qwen3.5:9b-q4_K_M` | model to pull |
| `OLLAMA_PORT` | `11434` | port Ollama listens on |
| `LATINA_DIR` | `$HOME/latinavoicepod` | where to clone latinavoicepod (Linux only) |
| `ASK_REPO` | `git+https://github.com/edantonio505/edstui.git` | override for forks |

## Re-running on the same machine

`install.sh` is safe to re-run, but a machine that's already been enrolled
once accumulates state (a Tailscale device identity, a systemd bind
override, possibly a stray leftover Ollama process) that can make a second
attempt behave unpredictably while debugging. To get a genuinely clean
slate on a machine you've already run this on — without reinstalling Ollama
or re-downloading the model — run:

```bash
curl -fsSL https://raw.githubusercontent.com/edantonio505/miniclosedai-node/main/reset.sh | bash
```

This leaves the tailnet (`tailscale down` + `logout`) and removes the Ollama
bind override, so the next `install.sh` run starts from scratch on those
two fronts. It doesn't delete the old backend row from miniaicloud — do
that from the admin Backends page so you're not left with a confusing
stale duplicate next to the new one.

## Why two scripts, not one

A true single polyglot file that runs correctly under both `bash` and
PowerShell isn't practical for something this involved (package manager
detection, service startup, JSON HTTP calls, prompting). `install.sh` and
`install.ps1` are one canonical command per platform, both producing the
same end state: an enrolled, enabled backend with Ollama + a model, `ask`,
and Tailscale SSH access.

## Status

This is Phase 3 of a larger plan (self-service node registration, this
installer, then remote orchestration from miniaicloud's admin GUI —
installing/removing a voice pod or switching a node's model without
re-running the installer). Phase 2 (miniaicloud's `/api/nodes/enroll` +
`/api/nodes/register`, node enrollment tokens, the admin "lock" action) is
built and tested (20 tests, all mocked — no live Tailscale calls yet).
A genuine live run of this installer needs a real Tailscale OAuth client
wired into miniaicloud first.
