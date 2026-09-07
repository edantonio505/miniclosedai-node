#Requires -RunAsAdministrator
<#
.SYNOPSIS
    miniclosedai-node — one-line installer for a compute node on the
    interdata network. Windows/PowerShell. See install.sh for the
    macOS/Linux equivalent — one canonical command per platform, both
    producing the same end state.

.DESCRIPTION
    Quick install (elevated PowerShell):
        irm https://raw.githubusercontent.com/edantonio505/miniclosedai-node/main/install.ps1 | iex

    What it does:
      1. Takes an enrollment token (minted by an admin in miniaicloud's
         admin panel: Node tokens page) — interactively, or via
         $env:MINICLOSEDAI_NODE_TOKEN to skip the prompt.
      2. Installs Ollama and pulls the model — default qwen3.5:4b (3.4GB
         weights), with OLLAMA_CONTEXT_LENGTH set explicitly to 32768
         rather than trusting Ollama's own VRAM-tiered auto-default (under
         24GiB VRAM, it silently picks a cramped 4096 tokens). Measured
         total footprint at that context: ~4.4GB, comfortably under a 6GB
         budget with real headroom on an 8GB card. (The 9b variant's
         weights alone are 6.6GB, already over 6GB before any context or
         overhead.)
      3. Installs Tailscale, exchanges the enrollment token for a join key
         via miniaicloud's POST /api/nodes/enroll, runs `tailscale up
         --ssh --unattended` (keeps running after logout), then reports
         this node's tailnet IP back via POST /api/nodes/register — the
         node is enabled on the interdata network immediately, no extra
         manual admin-approval step.
      4. Installs the `ask` CLI (edstui) via pipx.

    NOT included on Windows: the local Latina voice pod option from
    install.sh. latinavoicepod's own setup assumes apt-get and a
    CUDA-matched torch build via a bash script — genuinely separate work to
    port, not done here. A Windows node still contributes an Ollama model
    and gets SSH/ask access; it just can't run a local voice pod (yet).

.NOTES
    Env vars (all optional except the token, which prompts if unset):
      MINICLOSEDAI_HUB_URL     miniaicloud base URL (default: https://app.interdataresearch.ai)
      MINICLOSEDAI_NODE_TOKEN  enrollment token — skips the interactive prompt
      MINICLOSEDAI_NODE_NAME   this node's name on the network (default: hostname)
      OLLAMA_MODEL             model to pull (default: qwen3.5:4b)
      OLLAMA_PORT              port Ollama listens on (default: 11434)
      OLLAMA_CONTEXT_LENGTH    context window, in tokens (default: 32768)
      ASK_REPO                 edstui repo to pipx-install
#>

$ErrorActionPreference = "Stop"

$HubUrl     = if ($env:MINICLOSEDAI_HUB_URL)   { $env:MINICLOSEDAI_HUB_URL }   else { "https://app.interdataresearch.ai" }
$NodeName   = if ($env:MINICLOSEDAI_NODE_NAME) { $env:MINICLOSEDAI_NODE_NAME } else { $env:COMPUTERNAME }
$OllamaModel = if ($env:OLLAMA_MODEL) { $env:OLLAMA_MODEL } else { "qwen3.5:4b" }
$OllamaPort  = if ($env:OLLAMA_PORT)  { $env:OLLAMA_PORT }  else { 11434 }
$OllamaContextLength = if ($env:OLLAMA_CONTEXT_LENGTH) { $env:OLLAMA_CONTEXT_LENGTH } else { 32768 }
$AskRepo     = if ($env:ASK_REPO)     { $env:ASK_REPO }     else { "git+https://github.com/edantonio505/edstui.git" }

function Say($msg)  { Write-Host $msg }
function Ok($msg)   { Write-Host "OK  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "!   $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "ERR $msg" -ForegroundColor Red; exit 1 }

# `#Requires -RunAsAdministrator` above only takes effect when this file is
# executed directly — it is silently NOT enforced when run the documented
# way, `irm ... | iex`, since that evaluates a string rather than a script
# file. Check for real here so a non-elevated run fails clearly up front
# instead of partway through the winget/tailscale steps that need it.
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "This installer needs an elevated (Run as Administrator) PowerShell prompt."
}

Write-Host "miniclosedai-node installer" -ForegroundColor Cyan
Write-Host "  hub:  $HubUrl"
Write-Host "  name: $NodeName"
Write-Host ""

# ---------- 1. Enrollment token ----------
$Token = $env:MINICLOSEDAI_NODE_TOKEN
if (-not $Token) {
    $Token = Read-Host "Enrollment token (from miniaicloud admin -> Node tokens)"
}
if (-not $Token) { Fail "An enrollment token is required - mint one in miniaicloud's admin panel first." }

# ---------- 2. Ollama + model ----------
# Set OLLAMA_CONTEXT_LENGTH + OLLAMA_KEEP_ALIVE machine-wide (this script
# already runs elevated) BEFORE Ollama's own first launch, so a fresh
# install picks them up without a separate restart step. NOTE: if Ollama is
# already installed and already running (the else branch below), this alone
# will NOT change its behavior — a running process doesn't re-read the
# environment. That mirrors a known, separate gap in this script: unlike
# install.sh (which forces OLLAMA_HOST=0.0.0.0 via a systemd override +
# verifies it with `ss`), this Windows path has no equivalent "restart
# Ollama with new env vars" mechanism yet, for OLLAMA_HOST or these two. A
# Windows node would hit the exact same 127.0.0.1-only-bind problem
# install.sh had to fix on Linux. Untouched here deliberately — real,
# separate work.
[Environment]::SetEnvironmentVariable("OLLAMA_CONTEXT_LENGTH", "$OllamaContextLength", "Machine")
[Environment]::SetEnvironmentVariable("OLLAMA_KEEP_ALIVE", "-1", "Machine")
$env:OLLAMA_CONTEXT_LENGTH = "$OllamaContextLength"
$env:OLLAMA_KEEP_ALIVE = "-1"

if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Say "Installing Ollama..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --silent --accept-package-agreements --accept-source-agreements Ollama.Ollama
    } else {
        $installer = "$env:TEMP\OllamaSetup.exe"
        Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $installer
        Start-Process -FilePath $installer -ArgumentList "/SILENT" -Wait
    }
    Ok "Ollama installed"
} else {
    Ok "Ollama already installed"
    Warn "OLLAMA_CONTEXT_LENGTH/OLLAMA_KEEP_ALIVE were just set, but an already-running Ollama won't pick them up without a restart (quit it from the system tray and reopen, or 'taskkill /IM ollama.exe /F' then relaunch)."
}

# The Windows installer registers Ollama to start on login and serve
# in the background; give it a moment, then confirm before pulling.
$ollamaUp = $false
for ($i = 0; $i -lt 20; $i++) {
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$OllamaPort/api/tags" -TimeoutSec 2 | Out-Null
        $ollamaUp = $true
        break
    } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $ollamaUp) { Fail "Ollama isn't answering on :$OllamaPort - open the Ollama app once and re-run." }

Say "Pulling $OllamaModel (comfortably under a 6GB VRAM budget with room to spare)..."
& ollama pull $OllamaModel
Ok "model ready: $OllamaModel"

Say "Loading $OllamaModel into memory (keep_alive: forever)..."
try {
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$OllamaPort/api/generate" -ContentType "application/json" `
        -Body (@{ model = $OllamaModel; keep_alive = -1 } | ConvertTo-Json) -TimeoutSec 120 | Out-Null
    Ok "model loaded and resident (will not unload)"
} catch {
    Warn "couldn't pre-load $OllamaModel - it will still load on its first real request, just with a one-time delay"
}

# ---------- 3. Tailscale: enroll -> join -> register ----------
if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
    Say "Installing Tailscale..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --silent --accept-package-agreements --accept-source-agreements tailscale.tailscale
    } else {
        Fail "winget not found - install Tailscale manually from https://tailscale.com/download/windows and re-run."
    }
    Start-Sleep -Seconds 3
    Ok "Tailscale installed"
} else {
    Ok "Tailscale already installed"
}

Say "Requesting a Tailscale join key from $HubUrl..."
try {
    $enroll = Invoke-RestMethod -Method Post -Uri "$HubUrl/api/nodes/enroll" `
        -ContentType "application/json" -Body (@{ token = $Token } | ConvertTo-Json)
} catch {
    Fail "Enrollment failed - check the token and that $HubUrl is reachable. $($_.Exception.Message)"
}
$AuthKey = $enroll.tailscale_authkey
if (-not $AuthKey) { Fail "Hub didn't return a Tailscale auth key." }

Say "Joining the tailnet (this also enables Tailscale SSH - no separate keys to manage)..."
$tailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
if (-not (Test-Path $tailscaleExe)) { $tailscaleExe = "tailscale" }  # fall back to PATH
& $tailscaleExe up --authkey=$AuthKey --ssh --unattended --hostname=$NodeName --accept-routes
Ok "joined the tailnet as $NodeName"

$TsIp = $null
for ($i = 0; $i -lt 10; $i++) {
    $ip = (& $tailscaleExe ip -4 2>$null)
    if ($ip) { $TsIp = $ip.Trim(); break }
    Start-Sleep -Seconds 1
}
if (-not $TsIp) { Fail "Joined the tailnet but couldn't read this node's IP (tailscale ip -4)." }
Ok "tailnet IP: $TsIp"

Say "Registering with $HubUrl as an enabled backend..."
try {
    $register = Invoke-RestMethod -Method Post -Uri "$HubUrl/api/nodes/register" `
        -ContentType "application/json" `
        -Body (@{ token = $Token; name = $NodeName; tailscale_ip = $TsIp; ollama_port = [int]$OllamaPort } | ConvertTo-Json)
} catch {
    Fail "Registration failed. $($_.Exception.Message)"
}
Ok "registered: backend #$($register.backend_id) -> $($register.base_url)"

# ---------- 4. ask (edstui) ----------
$pyCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pyCmd) { $pyCmd = Get-Command py -ErrorAction SilentlyContinue }
if (-not $pyCmd) {
    Warn "Python not found - install it (winget install Python.Python.3.12), then: pip install --user pipx; pipx install $AskRepo"
} else {
    if (-not (Get-Command pipx -ErrorAction SilentlyContinue)) {
        Say "Installing pipx (for the ask CLI)..."
        & $pyCmd.Source -m pip install -q --user pipx
        & $pyCmd.Source -m pipx ensurepath | Out-Null
        $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
    }
    if (Get-Command pipx -ErrorAction SilentlyContinue) {
        Say "Installing the ask CLI (edstui)..."
        pipx install --force $AskRepo
        Ok "ask CLI ready - open a new terminal and run: ask"
    } else {
        Warn "pipx still not on PATH this session - open a new terminal and run: pipx install $AskRepo"
    }
}

Write-Host ""
Write-Host "Node enrolled on the interdata network" -ForegroundColor Green
Write-Host "  tailnet IP: $TsIp   model: $OllamaModel"
Write-Host "  Admin can now SSH in with: tailscale ssh $NodeName"
