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
2. Installs **Ollama** and pulls `qwen3.5:4b` (3.4GB weights). Also sets
   `OLLAMA_CONTEXT_LENGTH=32768` explicitly, rather than trusting Ollama's
   own VRAM-tiered auto-default (under 24GiB VRAM, it silently picks a
   cramped 4096 tokens). Measured total footprint at that context: ~4.4GB —
   comfortably under a 6GB budget with real headroom on an 8GB card. (The
   9b variant's weights alone are 6.6GB, already over 6GB before any
   context or overhead — set `OLLAMA_MODEL=qwen3.5:9b-q4_K_M` if you'd
   rather trade VRAM headroom for a larger model.)
3. Installs the **`ask`** CLI ([edstui](https://github.com/edantonio505/edstui))
   via pipx — done before network registration below, so a node still ends
   up with `ask` even if Tailscale/registration fails. Then optionally
   configures `ask` to reach the interdata relay **directly**: miniaicloud
   exposes a full native Ollama API at `$HUB_URL/api/*` (see
   `app/routers/ollama_native.py` in miniaicloud), so `ask`'s own Ollama
   client can talk to it with nothing in between — pointed there instead of
   at this node's own small model, `ask` can reach whatever's actually
   registered on the wider network (e.g. `qwen3.8:latest`), not just this
   one node. This needs a **relay API key** — an admin-minted `ApiKey` from
   miniaicloud's admin panel, a completely different credential from this
   node's own `node_api_key` (that one only authorizes
   `POST /api/nodes/{id}/backends`, nothing else). Prompted for
   interactively (blank to skip, leaving `ask` installed but unconfigured),
   or set `MINICLOSEDAI_NODE_ASK_API_KEY` to skip the prompt. **Note:** this
   key is shared across every node's `ask`, and it's a real secret — never
   commit it into this repo's source; keep it in your own private notes/env
   and pass it at install time.
4. *(Linux only)* Optionally installs a local **Latina voice pod**
   ([latinavoicepod](https://github.com/edantonio505/latinavoicepod)) —
   asked interactively, since it competes with the LLM for the same VRAM.
5. Registers with the relay, picking the network path automatically:
   - **Normal box:** installs **Tailscale**, exchanges the enrollment token
     for a join key via miniaicloud's `POST /api/nodes/enroll`, joins with
     Tailscale's own SSH feature enabled (`tailscale up --ssh`) — no
     separate SSH keypair to generate or distribute — then reports this
     node's tailnet IP via `POST /api/nodes/register` to become an
     **enabled** backend on the network immediately. Once enrolled, the
     admin can SSH straight to the node from anywhere
     (`tailscale ssh <node-name>`), and lock it out — disabling it and
     removing it from the tailnet in one action — from miniaicloud's
     Backends page.
   - **RunPod pod** (auto-detected via `$RUNPOD_POD_ID`, which every pod has
     set): skips Tailscale entirely and registers directly with the pod's
     own RunPod proxy URL (`https://<pod-id>-<port>.proxy.runpod.net`).
     RunPod pods have no `/dev/net/tun` access, so Tailscale can't provide
     real inbound reachability there — the daemon either refuses to start
     or falls back to userspace-networking mode, which only supports
     outbound connections. SSH access for these nodes is RunPod's own
     (dashboard/CLI), not Tailscale SSH — the admin's "Lock" button in
     miniaicloud still works (it just disables the backend row; there's no
     Tailscale device to remove for a node that never joined one).
6. *(Not offered on RunPod — see below)* Optionally enables **HuggingFace
   model support**: clones this repo's `manager/` control plane, sets up its
   lightweight venv plus the bare-metal transformers "shim" engine (the one
   that reliably works with no Docker/vLLM setup), optionally saves a
   HuggingFace token, and runs the manager as a systemd service (or a
   background process if systemd isn't present). This gives the node its
   own [`mcai-node`](#mcai-node---running-huggingface-models) CLI —
   `mcai-node run <hf_id>` downloads + serves any HF model behind an
   OpenAI-compatible API, and `mcai-node register <id>` adds it as a
   **second backend** on the interdata network, alongside the node's Ollama
   backend. Skipped on RunPod: a pod has no systemd to daemonize the
   manager with, and typically no Docker daemon of its own either.

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
| `OLLAMA_MODEL` | `qwen3.5:4b` | model to pull |
| `OLLAMA_PORT` | `11434` | port Ollama listens on |
| `OLLAMA_CONTEXT_LENGTH` | `32768` | context window, in tokens |
| `LATINA_DIR` | `$HOME/latinavoicepod` | where to clone latinavoicepod (Linux only) |
| `ASK_REPO` | `git+https://github.com/edantonio505/edstui.git` | override for forks |
| `MINICLOSEDAI_NODE_ASK_API_KEY` | *(prompts, blank = skip)* | relay API key so `ask` reaches interdata directly — never commit a real value |
| `MINICLOSEDAI_NODE_ASK_MODEL` | `qwen3.8:latest` | model `ask` asks the relay for |
| `MINICLOSEDAI_NODE_HF` | *(prompts, not offered on RunPod)* | `1`/`0` — enable HuggingFace model support |
| `MINICLOSEDAI_NODE_HF_TOKEN` | *(prompts if HF support is enabled)* | HuggingFace access token to save (only needed for gated models) |
| `MINICLOSEDAI_NODE_REPO_DIR` | `$HOME/miniclosedai-node` | where this repo gets cloned for the model manager + `mcai-node` CLI |
| `MINICLOSEDAI_NODE_HOME` | `$HOME/.miniclosedai-node` | where `mcai-node` keeps its local state (node id + API key) |

## `mcai-node` — running HuggingFace models

Once HuggingFace support is enabled (during install, or later by re-running
`install.sh`), the node gets its own CLI:

```bash
mcai-node analyze Qwen/Qwen2.5-7B-Instruct   # check size/gating/VRAM fit first
mcai-node run Qwen/Qwen2.5-7B-Instruct --wait
mcai-node ls                                  # see everything this node has launched
mcai-node logs <id> -f
mcai-node register <id>                       # add it as a 2nd backend on the network
mcai-node hf-token set                        # for gated repos (Llama, Gemma, ...)
```

`run` refuses by default if a model doesn't fit in currently-free VRAM (pass
`--force` to launch anyway) — it reads real GPU memory via `nvidia-smi`, so
the check already accounts for whatever the node's Ollama model has
resident, no separate step needed. The launch engine is auto-selected the
same way `miniclosedai-llm` does: Docker+vLLM if a daemon is reachable, else
a pip-installed native `vllm`, else the bare-metal transformers shim
(`manager/setup_shim.sh`) — the one that reliably works on a plain gaming PC
with neither of the others set up. GGUF-only repos aren't supported yet
(no llama.cpp engine on a node).

## Uninstalling

```bash
curl -fsSL https://raw.githubusercontent.com/edantonio505/miniclosedai-node/main/uninstall.sh | bash
```

Removes everything `install.sh` set up on this machine: Ollama (with a
confirmation prompt before deleting pulled model weights), Tailscale (and
leaves the tailnet), the `ask` CLI, a local latinavoicepod checkout, and —
if it was enabled — the model manager service, its cloned repo, and the
`mcai-node` CLI. There's still no self-deregister endpoint, so delete the
node's old backend row(s) from miniaicloud's admin Backends page afterward.

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

## Testing installer changes before real hardware

```bash
test/docker-smoke.sh
```

Runs `install.sh` inside a genuinely clean `ubuntu:24.04` container (curl/
python3/`ss` preinstalled, matching a normal Ubuntu box — but deliberately
no git or pipx, the two dependencies that have silently gone missing on
real hardware before) and checks that git, pipx, `ask`, and Ollama all end
up installed correctly. It can't validate real GPU inference or the actual
tailnet path a real relay would use — node registration is expected to
fail without a real enrollment token, and that's treated as a pass as long
as everything before it succeeded. Not a replacement for a real-hardware
test, just a fast way to catch this class of "assumed present" bug first.

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
