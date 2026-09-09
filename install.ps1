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
         overhead.) Also forces OLLAMA_HOST=0.0.0.0 by restarting Ollama
         with that env var actually set on the new process (a registry-only
         change doesn't reach an already-running Ollama), opens the port in
         Windows Defender Firewall, and verifies the real bind via
         Get-NetTCPConnection before proceeding.
      3. Installs Tailscale, exchanges the enrollment token for a join key
         via miniaicloud's POST /api/nodes/enroll, runs `tailscale up
         --ssh --unattended` (keeps running after logout), opens a
         firewall rule scoped to the Tailscale adapter, then proves this
         node is actually reachable at its own tailnet address (the same
         path the relay's health probe uses) before ever registering —
         refuses to register a backend known to be unreachable. Reports the
         node's base_url via POST /api/nodes/register — enabled on the
         interdata network immediately, no extra manual admin-approval step.
      4. Installs the `ask` CLI (edstui) via pipx, then optionally points it
         at the interdata relay directly (needs a relay API key — an
         admin-minted ApiKey, not this node's own registration secret).

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
      MINICLOSEDAI_NODE_ASK_API_KEY  relay API key so ask reaches interdata directly (skips the prompt; blank = skip entirely)
      MINICLOSEDAI_NODE_ASK_MODEL    model ask asks the relay for (default: qwen3.8:latest)
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
# Ollama binds 127.0.0.1 only by default — the exact "port refused over the
# tailnet even though everything else is fine" problem install.sh had to
# fix for both Linux (systemd override) and macOS (launchctl setenv + app
# restart). A registry env-var change alone does NOT affect a process
# already running before this script ran, and Windows never broadcasts that
# change to it — so the only mechanism that reliably works here too: set
# the vars on THIS elevated process first (a child process always inherits
# its parent's process-level environment immediately), then actually stop
# and relaunch Ollama so the new process is the one that picks them up.
$OllamaHostValue = "0.0.0.0:$OllamaPort"
[Environment]::SetEnvironmentVariable("OLLAMA_HOST", $OllamaHostValue, "Machine")
[Environment]::SetEnvironmentVariable("OLLAMA_CONTEXT_LENGTH", "$OllamaContextLength", "Machine")
[Environment]::SetEnvironmentVariable("OLLAMA_KEEP_ALIVE", "-1", "Machine")
$env:OLLAMA_HOST = $OllamaHostValue
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
    Start-Sleep -Seconds 2   # the installer also launches Ollama once, using the pre-install env
} else {
    Ok "Ollama already installed"
}

Say "Restarting Ollama so it picks up OLLAMA_HOST=$OllamaHostValue..."
Get-Process -Name "ollama", "ollama app" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
# Prefer relaunching the tray app (same UX as a normal install — it starts
# `ollama.exe serve` itself, inheriting the env we just set on this
# process) and fall back to the bare server binary if only that exists.
$ollamaAppExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
if (Test-Path $ollamaAppExe) {
    Start-Process -FilePath $ollamaAppExe -WindowStyle Hidden
} else {
    $ollamaExe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if (-not $ollamaExe) { $ollamaExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" }
    if (-not (Test-Path $ollamaExe)) { Fail "Can't find ollama.exe to restart it - check the Ollama install." }
    Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden
}

# Windows Defender Firewall blocks a freshly-listening port from remote
# hosts by default — same class of gap as macOS's Application Firewall and
# Linux's ufw, both of which install.sh already handles proactively. This
# script already runs elevated, so it can just be created outright.
if (-not (Get-NetFirewallRule -DisplayName "miniclosedai-node: Ollama" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "miniclosedai-node: Ollama" -Direction Inbound -Protocol TCP `
        -LocalPort $OllamaPort -Action Allow -ErrorAction SilentlyContinue | Out-Null
}

$ollamaUp = $false
for ($i = 0; $i -lt 20; $i++) {
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$OllamaPort/api/tags" -TimeoutSec 2 | Out-Null
        $ollamaUp = $true
        break
    } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $ollamaUp) { Fail "Ollama isn't answering on :$OllamaPort after restarting it - check Task Manager for a stuck ollama.exe process." }

# The check above only proves loopback reachability — 127.0.0.1-only
# binding would pass it too. Get-NetTCPConnection is the Windows-native
# equivalent of install.sh's `ss`/`lsof` bind check.
$bound = Get-NetTCPConnection -LocalPort $OllamaPort -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalAddress -eq "0.0.0.0" -or $_.LocalAddress -eq "::" }
if (-not $bound) {
    Fail "Ollama is listening on :$OllamaPort but only on a loopback/specific address, not 0.0.0.0 - the relay would not be able to reach this node. Check 'Get-NetTCPConnection -LocalPort $OllamaPort' and the OLLAMA_HOST env var."
}
Ok "Ollama confirmed listening on all interfaces (:$OllamaPort)"

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

# Scope a second firewall rule specifically to the Tailscale adapter, same
# as install.sh's `ufw allow in on tailscale0` — belt-and-suspenders with
# the all-interfaces rule added in step 2, and the one that actually
# matters for reachability over the tailnet specifically.
try {
    if (-not (Get-NetFirewallRule -DisplayName "miniclosedai-node: Ollama (Tailscale)" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "miniclosedai-node: Ollama (Tailscale)" -Direction Inbound -Protocol TCP `
            -LocalPort $OllamaPort -InterfaceAlias "Tailscale" -Action Allow -ErrorAction Stop | Out-Null
    }
} catch {
    Warn "couldn't scope a firewall rule to the Tailscale adapter ($($_.Exception.Message)) - the all-interfaces rule from step 2 should still cover this."
}

# The definitive test: curl this node's OWN tailnet address, not loopback —
# the exact address:port the relay's health probe will use. Tailscale SSH
# working is NOT evidence this works: it's authorized through its own
# separate ACL policy, independent of general port reachability. Refuse to
# register a backend with the relay until this has actually been proven
# over the real path, rather than finding out afterward from miniaicloud's
# side — the same guarantee install.sh already makes on Linux/macOS.
Say "Verifying the node is reachable at its tailnet address (the same path the relay will use)..."
$reachable = $false
try {
    Invoke-RestMethod -Uri "http://$($TsIp):$($OllamaPort)/api/tags" -TimeoutSec 5 | Out-Null
    $reachable = $true
} catch {}
if (-not $reachable) {
    Fail "Ollama's bind was already confirmed correct (0.0.0.0:$OllamaPort), but $($TsIp):$($OllamaPort) still refuses a connection from this same machine - almost certainly Windows Defender Firewall blocking the Tailscale interface, not an Ollama config problem. Check: Get-NetFirewallRule -DisplayName 'miniclosedai-node: Ollama (Tailscale)' | Get-NetFirewallPortFilter — or open Windows Defender Firewall -> Advanced Settings -> Inbound Rules and allow TCP $OllamaPort on the Tailscale adapter, then re-run."
}
Ok "confirmed reachable at $($TsIp):$($OllamaPort) - the same address the relay will probe"

$NodeBaseUrl = "http://$($TsIp):$($OllamaPort)"
Say "Registering with $HubUrl as an enabled backend..."
try {
    $register = Invoke-RestMethod -Method Post -Uri "$HubUrl/api/nodes/register" `
        -ContentType "application/json" `
        -Body (@{ token = $Token; name = $NodeName; base_url = $NodeBaseUrl } | ConvertTo-Json)
} catch {
    Fail "Registration failed. $($_.Exception.Message)"
}
Ok "registered: backend #$($register.backend_id) -> $($register.base_url)"

# ---------- 4. ask (edstui) ----------
# `pipx install git+https://...` needs git on PATH just to clone the repo —
# without it this step fails silently on any box that doesn't already
# happen to have git installed. Not fatal: a missing `ask` CLI shouldn't
# block the node's actual registration, which never touches git.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Say "Installing git (required by pipx to install the ask CLI from GitHub)..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --silent --accept-package-agreements --accept-source-agreements Git.Git
        $env:Path = "$env:ProgramFiles\Git\cmd;$env:Path"
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Warn "couldn't install git automatically - the ask CLI install step below will fail until it's installed manually (winget install Git.Git)"
    } else {
        Ok "git installed"
    }
}

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

        # `ask` talks to whatever Ollama-shaped host EDS_TUI_URL points at
        # using Ollama's own native wire protocol — miniaicloud (the relay)
        # exposes exactly that natively at $HubUrl/api/{tags,chat,...},
        # gated by a genuine relay API key (an ApiKey tied to a user, NOT
        # this node's own node_api_key — a completely separate credential).
        # Pointing `ask` there instead of at this node's own small model is
        # what lets it reach the wider interdata network. Set at User scope
        # via the registry, not a profile file — unlike install.sh's
        # ~/.bash_aliases/~/.zshrc (which depend on which shell profile a
        # new terminal happens to source), a User-scope Windows env var is
        # inherited by every new process automatically, no such dependency.
        $AskApiKey = $env:MINICLOSEDAI_NODE_ASK_API_KEY
        if (-not $AskApiKey) {
            $AskApiKey = Read-Host "Interdata relay API key for ask (optional - lets ask reach the whole network, not just this node; mint one in miniaicloud admin -> API keys; blank to skip)"
        }
        if ($AskApiKey) {
            $AskModel = if ($env:MINICLOSEDAI_NODE_ASK_MODEL) { $env:MINICLOSEDAI_NODE_ASK_MODEL } else { "qwen3.8:latest" }
            [Environment]::SetEnvironmentVariable("EDS_TUI_URL", $HubUrl, "User")
            [Environment]::SetEnvironmentVariable("EDS_TUI_TOKEN", $AskApiKey, "User")
            [Environment]::SetEnvironmentVariable("EDS_TUI_MODEL", $AskModel, "User")
            Ok "ask configured to reach interdata directly - open a new terminal to pick it up"
        } else {
            Say "No relay API key given - ask is installed but not yet pointed at interdata. Set EDS_TUI_URL/EDS_TUI_TOKEN later (see miniclosedai-node's README)."
        }
    } else {
        Warn "pipx still not on PATH this session - open a new terminal and run: pipx install $AskRepo"
    }
}

Write-Host ""
Write-Host "Node enrolled on the interdata network" -ForegroundColor Green
Write-Host "  tailnet IP: $TsIp   model: $OllamaModel"
Write-Host "  Admin can now SSH in with: tailscale ssh $NodeName"
