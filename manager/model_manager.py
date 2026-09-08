#!/usr/bin/env python3
"""Core engine for the miniclosedai-node HuggingFace model manager.

A trimmed port of miniclosedai-llm's control plane, sized for a single
compute node rather than a curated multi-model dashboard: no models.yaml/
profile system (a node launches whatever hf_id you give it, ad-hoc), no
GGUF/llama.cpp engine (out of scope for a first pass — safetensors only).

Owns:
  * the persistent model registry (`models.local.json`)
  * HuggingFace-id normalization + served-name/port allocation
  * a pluggable launch Engine — DockerEngine (vLLM in a container, if a
    docker daemon is reachable), NativeEngine (`vllm serve` subprocess, if
    vLLM is pip-installed), ShimEngine (bare-metal transformers — the one
    that reliably works on a plain gaming PC with no Docker/vLLM setup)
  * status derivation (stopped -> pulling/starting -> downloading -> loading -> ready/error)
  * a VRAM fit-check before launch (see available_capacity_gb())

Everything heavy (CUDA, torch, vLLM) lives inside the container/subprocess —
this module only shells out to `docker` / `vllm` / `nvidia-smi`.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent
STATE_FILE = ROOT / "models.local.json"
RUN_DIR = ROOT / ".run"
PORT_START = 8001
CONTAINER_PREFIX = "vlm-"
STATE_VERSION = 1
DEFAULT_VLLM_IMAGE = "vllm/vllm-openai:latest"

# Default serving params for a freshly-launched model.
PARAM_DEFAULTS: dict[str, Any] = {
    "max_model_len": 16384,
    "gpu_memory_util": 0.90,
    "tensor_parallel": 1,
    "max_images": 5,
    "quantization": None,
    "trust_remote_code": False,
    "mm_processor_kwargs": None,
    "hf_overrides": None,
    "extra_args": [],
}


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default) or default


def hf_home() -> str:
    return os.path.expanduser(_env("HF_HOME", os.path.expanduser("~/.cache/huggingface")))


def vllm_image() -> str:
    return _env("VLLM_IMAGE", DEFAULT_VLLM_IMAGE)


def _build_vllm_args(m: dict, *, api_key: str | None = None) -> list[str]:
    """Turn a model dict (hf_id/served_name/port/params) into the argument
    list that follows `vllm serve`. Trimmed from miniclosedai-llm's
    _args.build_args() — no models.yaml/profile system here, so this takes
    the launch's own fields directly instead of looking one up by name."""
    a: list[str] = [m["hf_id"]]
    a += ["--served-model-name", str(m["served_name"])]
    a += ["--host", "0.0.0.0", "--port", str(m["port"])]
    a += ["--max-model-len", str(m["max_model_len"])]
    a += ["--gpu-memory-utilization", str(m["gpu_memory_util"])]
    a += ["--tensor-parallel-size", str(m.get("tensor_parallel", 1))]
    # Multiple images per prompt — only for multimodal models.
    if m.get("max_images"):
        a += ["--limit-mm-per-prompt", json.dumps({"image": int(m["max_images"])})]
    if m.get("quantization"):
        a += ["--quantization", str(m["quantization"])]
    if m.get("trust_remote_code"):
        a += ["--trust-remote-code"]
    if m.get("mm_processor_kwargs"):
        a += ["--mm-processor-kwargs", str(m["mm_processor_kwargs"])]
    if m.get("hf_overrides"):
        a += ["--hf-overrides", str(m["hf_overrides"])]
    if api_key:
        a += ["--api-key", str(api_key)]
    a += list(m.get("extra_args", []) or [])
    return a


# ---- transformers shim (bare-metal safetensors / VLM) -----------------------
# The shim (shim/server.py) serves any HF model behind an OpenAI-compatible API
# using plain `transformers` — the fallback for a node with no Docker daemon
# and no pip-installed vLLM (the common case on a plain gaming PC). torch is
# huge, so it runs in its own venv created by ./setup_shim.sh rather than the
# manager's own (lightweight, no-torch) env.
_SHIM_VENV = ROOT / ".shim-venv"


def shim_python() -> str | None:
    """Resolve a python that can run the transformers shim.

    Order: $SHIM_PYTHON -> ./.shim-venv/bin/python -> this interpreter iff it
    can already import torch + transformers. Returns None when nothing usable
    is present.

    The venv path is gated on a `.ready` marker, not just directory
    existence: `python -m venv` creates the directory in the first second of
    ./setup_shim.sh, but torch/transformers take minutes to install
    afterward — checking existence alone would make an in-progress install
    look "ready" the moment it started.
    """
    env = _env("SHIM_PYTHON")
    if env and Path(env).exists():
        return env
    venv_py = _SHIM_VENV / "bin" / "python"
    if venv_py.exists() and (_SHIM_VENV / ".ready").exists():
        return str(venv_py)
    try:
        __import__("torch")
        __import__("transformers")
        return sys.executable
    except Exception:
        return None


def shim_build_status() -> dict:
    """Is ./setup_shim.sh running in the background right now? {building,
    progress} so a status check can show 'installing shim... <last log
    line>' instead of a bare 'run ./setup_shim.sh' while torch/transformers
    are still downloading."""
    log = RUN_DIR / "shim-setup.log"
    pidf = RUN_DIR / "shim-setup.pid"
    building = False
    try:
        os.kill(int(pidf.read_text().strip()), 0)  # signal 0 = liveness check
        building = True
    except (OSError, ValueError):
        try:
            building = log.exists() and (time.time() - log.stat().st_mtime) < 20
        except OSError:
            building = False
    if not building:
        return {"building": False, "progress": ""}
    progress = ""
    try:
        lines = [l.strip() for l in log.read_text(errors="replace").splitlines() if l.strip()]
        if lines:
            progress = lines[-1][:60]
    except OSError:
        pass
    return {"building": True, "progress": progress}


def lan_ip() -> str:
    """Best-effort primary LAN IP. Opens a UDP socket toward a public address
    — no packets are actually sent; this just makes the OS pick the outbound
    interface so we can read its IP."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
        finally:
            s.close()
    except OSError:
        return ""


# --------------------------------------------------------------------- HF analysis
_VL_TAGS = {"image-text-to-text", "visual-question-answering",
            "image-to-text", "video-text-to-text", "any-to-any"}


def unified_memory() -> dict:
    """Total / available SYSTEM RAM in GB, from /proc/meminfo.

    Only meaningful as a capacity proxy on genuine unified-memory parts
    (Jetson, GB10), where the GPU shares system LPDDR and nvidia-smi can't
    report real VRAM numbers. See available_capacity_gb(), which prefers
    real discrete VRAM whenever nvidia-smi can report it — the normal case
    for this project's actual target (a discrete-GPU gaming PC).
    """
    total = avail = 0
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                total = int(line.split()[1]) // 1024 // 1024
            elif line.startswith("MemAvailable:"):
                avail = int(line.split()[1]) // 1024 // 1024
    except OSError:
        pass
    return {"total_gb": total, "available_gb": avail}


def gpu_info() -> dict:
    if not shutil.which("nvidia-smi"):
        return {"gpus": [], "error": "nvidia-smi not found"}
    r = _run(["nvidia-smi",
              "--query-gpu=index,name,memory.total,memory.used,utilization.gpu",
              "--format=csv,noheader,nounits"], timeout=10)
    if r.returncode != 0:
        return {"gpus": [], "error": (r.stderr or "nvidia-smi failed").strip()}

    def _num(x):
        # GB10 / unified-memory parts report "[N/A]" for VRAM fields.
        try:
            return int(float(x))
        except (TypeError, ValueError):
            return None

    gpus = []
    for line in r.stdout.strip().splitlines():
        c = [x.strip() for x in line.split(",")]
        if len(c) >= 5:
            gpus.append({"index": _num(c[0]) or 0, "name": c[1],
                         "mem_total_mb": _num(c[2]), "mem_used_mb": _num(c[3]),
                         "util_pct": _num(c[4]) or 0})
    return {"gpus": gpus}


def available_capacity_gb() -> dict:
    """Real-time free capacity for the fit-check in analyze_model(): actual
    discrete VRAM when nvidia-smi reports real numbers (this project's real
    target — a discrete-GPU gaming PC), falling back to system RAM only for
    genuine unified-memory parts (GB10, Jetson) where nvidia-smi's memory
    fields come back "[N/A]".

    A LIVE read already reflects anything currently resident in that pool —
    including whatever Ollama has loaded, since it's genuinely occupying
    real VRAM regardless of which process holds it — so no separate "ask
    Ollama how much it's using and subtract that" step is needed on top of
    this; doing so would double-subtract and make the guardrail overly
    conservative.
    """
    gpus = gpu_info().get("gpus") or []
    if gpus and gpus[0].get("mem_total_mb") is not None:
        g = gpus[0]
        total_mb = g["mem_total_mb"]
        used_mb = g.get("mem_used_mb") or 0
        return {
            "total_gb": round(total_mb / 1024, 1),
            "available_gb": round(max(total_mb - used_mb, 0) / 1024, 1),
        }
    return unified_memory()


def _dir_size_gb(path: Path) -> float:
    total = 0
    for p in path.rglob("*"):
        try:
            st = p.lstat()
        except OSError:
            continue
        if not p.is_symlink() and st.st_mode & 0o170000 == 0o100000:
            total += st.st_size
    return round(total / 1e9, 1)


def list_cached_models() -> list[dict]:
    """Enumerate already-downloaded HuggingFace repos that are runnable LLMs
    (reads each repo's local config.json, no network)."""
    hub = Path(hf_home()) / "hub"
    out: list[dict] = []
    if not hub.is_dir():
        return out
    for d in sorted(hub.glob("models--*")):
        hf_id = d.name[len("models--"):].replace("--", "/")
        cfgs = list(d.glob("snapshots/*/config.json"))
        if not cfgs:
            continue
        try:
            cfg = json.loads(cfgs[0].read_text())
        except (OSError, ValueError):
            continue
        archs = cfg.get("architectures") or []
        multimodal = "vision_config" in cfg
        is_causal = any("ForCausalLM" in a for a in archs)
        if not (multimodal or is_causal):
            continue
        out.append({"hf_id": hf_id, "size_gb": _dir_size_gb(d),
                    "multimodal": bool(multimodal), "arch": (archs or [None])[0]})
    return out


def is_cached(hf_id: str) -> bool:
    try:
        hf_id = normalize_hf_id(hf_id)
    except ValueError:
        return False
    snaps = Path(hf_home()) / "hub" / ("models--" + hf_id.replace("/", "--")) / "snapshots"
    if snaps.is_dir():
        for snap in snaps.iterdir():
            for ext in ("*.safetensors", "*.bin", "*.pt"):
                if any(snap.glob(ext)):
                    return True
    return False


def delete_cached_model(hf_id: str) -> bool:
    import shutil as _sh
    hf_id = normalize_hf_id(hf_id)
    d = Path(hf_home()) / "hub" / ("models--" + hf_id.replace("/", "--"))
    if d.is_dir():
        _sh.rmtree(d, ignore_errors=True)
        return True
    return False


def _hf_get(url: str, timeout: float = 12.0):
    headers = {"User-Agent": "miniclosedai-node"}
    token = _env("HF_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        req = Request(url, headers=headers, method="GET")
        with urlopen(req, timeout=timeout) as r:
            if r.status != 200:
                return None
            return json.loads(r.read().decode())
    except (URLError, OSError, ValueError, TimeoutError):
        return None


# ---- Hugging Face token --------------------------------------------------------
ENV_FILE = ROOT / ".env"


def _mask_token(tok: str) -> str:
    if not tok:
        return ""
    return "****" if len(tok) <= 8 else f"{tok[:3]}…{tok[-4:]}"


def _hf_whoami(token: str):
    headers = {"User-Agent": "miniclosedai-node", "Authorization": f"Bearer {token}"}
    try:
        req = Request("https://huggingface.co/api/whoami-v2", headers=headers, method="GET")
        with urlopen(req, timeout=12.0) as r:
            if r.status != 200:
                return None
            return json.loads(r.read().decode())
    except (URLError, OSError, ValueError, TimeoutError):
        return None


def _apply_hf_token_env(token: str) -> None:
    for name in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
        if token:
            os.environ[name] = token
        else:
            os.environ.pop(name, None)


def _persist_env_var(key: str, value: str) -> None:
    lines = ENV_FILE.read_text().splitlines() if ENV_FILE.exists() else []
    for i, ln in enumerate(lines):
        stripped = ln.lstrip()
        if stripped.startswith(key + "=") or stripped.startswith(key + " ="):
            lines[i] = f"{key}={value}"
            break
    else:
        lines.append(f"{key}={value}")
    ENV_FILE.write_text("\n".join(lines) + "\n")


def hf_token_status() -> dict:
    tok = _env("HF_TOKEN")
    if not tok:
        return {"present": False, "masked": "", "user": None, "valid": None}
    who = _hf_whoami(tok)
    return {"present": True, "masked": _mask_token(tok),
            "user": (who or {}).get("name"), "valid": who is not None}


def set_hf_token(token: str, persist: bool = True) -> dict:
    token = (token or "").strip()
    if not token:
        return {"ok": False, "error": "Token is empty — paste a token from "
                                      "huggingface.co/settings/tokens."}
    who = _hf_whoami(token)
    _apply_hf_token_env(token)
    persisted = False
    warning = None
    if persist:
        try:
            _persist_env_var("HF_TOKEN", token)
            persisted = True
        except OSError as exc:
            warning = f"Applied for this session but couldn't write .env: {exc}"
    return {"ok": True, "valid": who is not None, "user": (who or {}).get("name"),
            "masked": _mask_token(token), "persisted": persisted, "warning": warning}


def clear_hf_token() -> None:
    _apply_hf_token_env("")
    try:
        _persist_env_var("HF_TOKEN", "")
    except OSError:
        pass


_GATED_MARKERS = (
    "gatedrepoerror", "gated repo", "you are trying to access a gated repo",
    "cannot access gated repo", "is restricted. you must have access",
    "access to model",
)


def is_gated_auth_error(text: str | None) -> bool:
    if not text:
        return False
    low = text.lower()
    if any(m in low for m in _GATED_MARKERS):
        return True
    return ("401 client error" in low or "403 client error" in low) and "huggingface" in low


def _bytes_per_param(dtype: str | None, tags: list[str]) -> float:
    t = " ".join(tags).lower()
    if any(q in t for q in ("4bit", "int4", "awq", "gptq", "-4bit")):
        return 0.5
    if "8bit" in t or "int8" in t:
        return 1.0
    d = (dtype or "").upper()
    if d.startswith("F32") or d.startswith("FP32"):
        return 4.0
    if "F8" in d or "FP8" in d or d.startswith("I8"):
        return 1.0
    if d.startswith("I4") or d.startswith("U4"):
        return 0.5
    return 2.0  # BF16 / F16 default


def _repo_tree(hf_id: str) -> list[tuple[str, int]]:
    tree = _hf_get(f"https://huggingface.co/api/models/{hf_id}/tree/main?recursive=true")
    if not isinstance(tree, list):
        return []
    out = []
    for e in tree:
        p = e.get("path", "")
        s = (e.get("lfs") or {}).get("size") or e.get("size") or 0
        out.append((p, int(s or 0)))
    return out


def _tree_weight_gb(hf_id: str) -> float | None:
    exts = (".safetensors", ".bin", ".pt", ".pth")
    total = sum(s for p, s in _repo_tree(hf_id) if p.endswith(exts))
    return total / 1e9 if total else None


def _has_gguf(files: list[tuple[str, int]]) -> bool:
    return any(p.lower().endswith(".gguf") for p, _ in files)


def analyze_model(hf_id: str) -> dict:
    """Inspect a HF repo before downloading: existence, gating, type, size, fit."""
    try:
        hf_id = normalize_hf_id(hf_id)
    except ValueError as e:
        return {"exists": False, "hf_id": hf_id, "error": str(e)}

    info = _hf_get(f"https://huggingface.co/api/models/{hf_id}")
    cap = available_capacity_gb()
    token_present = bool(_env("HF_TOKEN"))
    if info is None:
        return {"exists": False, "hf_id": hf_id, "hf_token_present": token_present,
                "available_gb": cap["available_gb"], "total_gb": cap["total_gb"],
                "error": "Not found on HuggingFace — check the id, or it may be "
                         "gated/private and need a valid HF_TOKEN."}

    pipeline = info.get("pipeline_tag") or ""
    tags = [str(t) for t in (info.get("tags") or [])]
    gated = bool(info.get("gated"))

    tree = _repo_tree(hf_id)
    has_safetensors = any(p.endswith(".safetensors") for p, _ in tree)
    is_gguf = _has_gguf(tree) and not has_safetensors

    st = info.get("safetensors") or {}
    params = st.get("total")
    dtype = None
    if isinstance(st.get("parameters"), dict) and st["parameters"]:
        dtype = max(st["parameters"], key=st["parameters"].get)
    if params:
        size_gb = params * _bytes_per_param(dtype, tags) / 1e9
    else:
        size_gb = _tree_weight_gb(hf_id)

    cfg = _hf_get(f"https://huggingface.co/{hf_id}/resolve/main/config.json") or {}
    multimodal = (pipeline in _VL_TAGS or any(t in _VL_TAGS for t in tags)
                  or "vision_config" in cfg)

    tcfg = cfg.get("text_config") if isinstance(cfg.get("text_config"), dict) else cfg
    max_ctx = (tcfg.get("max_position_embeddings") or cfg.get("max_position_embeddings")
               or cfg.get("max_model_len") or cfg.get("n_positions"))

    text_gen = pipeline in ("", "text-generation", "text2text-generation",
                            "conversational") or multimodal

    need_gb = round(size_gb * 1.15 + 1.0, 1) if size_gb else None
    fits = bool(need_gb and need_gb <= cap["available_gb"])

    return {
        "exists": True, "hf_id": hf_id,
        "pipeline_tag": pipeline, "multimodal": multimodal,
        "is_llm": (text_gen and not is_gguf), "gated": gated,
        "hf_token_present": token_present,
        "params": params, "dtype": dtype, "max_ctx": max_ctx,
        "fmt": "gguf" if is_gguf else "safetensors",
        # No llama.cpp engine on a node (first pass) — GGUF-only repos can be
        # inspected but not launched. See Manager.add()'s check.
        "supported": not is_gguf,
        "size_gb": round(size_gb, 1) if size_gb else None,
        "need_gb": need_gb, "available_gb": cap["available_gb"],
        "total_gb": cap["total_gb"], "fits": fits,
    }


# --------------------------------------------------------------------------- helpers
def normalize_hf_id(raw: str) -> str:
    s = (raw or "").strip()
    if s.startswith(("http://", "https://", "hf.co", "huggingface.co", "www.")):
        s = re.sub(r"^[a-z]+://", "", s)
        s = re.sub(r"^(www\.)?(huggingface\.co|hf\.co)/", "", s)
    s = s.split("?")[0].split("#")[0]
    parts = [p for p in s.split("/") if p]
    if len(parts) >= 2:
        s = f"{parts[0]}/{parts[1]}"
    s = s.removesuffix(".git")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", s):
        raise ValueError(
            f"'{raw}' is not a valid HuggingFace repo id. Expected 'owner/name' "
            "or a https://huggingface.co/owner/name URL."
        )
    return s


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s[:40] or "model"


def _port_is_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("0.0.0.0", port))
            return True
        except OSError:
            return False


def _run(argv: list[str], timeout: int = 20) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError:
        return subprocess.CompletedProcess(argv, 127, "", f"{argv[0]}: not found")


def probe_models(port: int, timeout: float = 2.0) -> tuple[bool, list[str]]:
    try:
        req = Request(f"http://127.0.0.1:{port}/v1/models", method="GET")
        with urlopen(req, timeout=timeout) as r:
            if r.status != 200:
                return False, []
            data = json.loads(r.read().decode())
            return True, [m.get("id", "") for m in data.get("data", [])]
    except (URLError, OSError, ValueError, TimeoutError):
        return False, []


# --------------------------------------------------------------------------- registry
@dataclass
class ModelEntry:
    id: str
    hf_id: str
    served_name: str
    port: int
    params: dict = field(default_factory=lambda: dict(PARAM_DEFAULTS))
    desired_state: str = "stopped"   # "running" | "stopped"
    engine: str = ""                 # which engine last launched it
    multimodal: bool = True
    size_gb: float = 0.0
    error: str = ""
    created_at: str = ""

    def to_dict(self) -> dict:
        return {
            "id": self.id, "hf_id": self.hf_id, "served_name": self.served_name,
            "port": self.port, "params": self.params,
            "desired_state": self.desired_state, "engine": self.engine,
            "multimodal": self.multimodal, "size_gb": self.size_gb,
            "created_at": self.created_at,
        }

    @staticmethod
    def from_dict(d: dict) -> "ModelEntry":
        params = dict(PARAM_DEFAULTS)
        params.update(d.get("params") or {})
        return ModelEntry(
            id=d["id"], hf_id=d["hf_id"], served_name=d["served_name"],
            port=int(d["port"]), params=params,
            desired_state=d.get("desired_state", "stopped"),
            engine=d.get("engine", ""), multimodal=d.get("multimodal", True),
            size_gb=d.get("size_gb", 0.0), created_at=d.get("created_at", ""),
        )


# --------------------------------------------------------------------------- engines
class Engine:
    """Launch backend interface. Implementations: DockerEngine, NativeEngine, ShimEngine."""

    name = "base"

    def available(self) -> tuple[bool, str]:
        raise NotImplementedError

    def launch(self, e: ModelEntry) -> None:
        raise NotImplementedError

    def stop(self, e: ModelEntry) -> None:
        raise NotImplementedError

    def is_alive(self, e: ModelEntry) -> bool:
        raise NotImplementedError

    def state(self, e: ModelEntry) -> str:
        """Coarse runtime state: 'running' | 'exited' | 'absent'."""
        return "running" if self.is_alive(e) else "absent"

    def recent_logs(self, e: ModelEntry, lines: int = 60) -> str:
        raise NotImplementedError

    def open_log_stream(self, e: ModelEntry) -> subprocess.Popen | None:
        raise NotImplementedError

    def discover(self) -> list[dict]:
        """Find live instances this engine owns (for startup reconcile)."""
        return []

    def _vllm_args(self, e: ModelEntry) -> list[str]:
        m = {"hf_id": e.hf_id, "served_name": e.served_name, "port": e.port, **e.params}
        api_key = _env("VLLM_API_KEY") or None
        return _build_vllm_args(m, api_key=api_key)


class DockerEngine(Engine):
    name = "docker"

    def container(self, e: ModelEntry) -> str:
        return f"{CONTAINER_PREFIX}{e.served_name}"

    def _log(self, e: ModelEntry) -> Path:
        return RUN_DIR / f"{e.served_name}.docker.log"

    def available(self) -> tuple[bool, str]:
        if not shutil.which("docker"):
            return False, "docker CLI not found on PATH"
        r = _run(["docker", "info"], timeout=15)
        if r.returncode != 0:
            return False, "docker daemon not reachable (is the user in the 'docker' group?)"
        return True, "docker daemon reachable"

    def _inspect_status(self, e: ModelEntry) -> str | None:
        r = _run(["docker", "inspect", "-f", "{{.State.Status}}", self.container(e)], timeout=15)
        return r.stdout.strip() if r.returncode == 0 else None

    def state(self, e: ModelEntry) -> str:
        s = self._inspect_status(e)
        if s is None:
            return "absent"
        return "running" if s == "running" else "exited"

    def launch(self, e: ModelEntry) -> None:
        """Non-blocking: pull the image (streamed to a log) then `docker run -d`."""
        RUN_DIR.mkdir(exist_ok=True)
        name = self.container(e)
        image = vllm_image()
        token = _env("HF_TOKEN")
        run_argv = [
            "docker", "run", "-d", "--name", name,
            "--gpus", "all", "--ipc=host", "--shm-size", "16g",
            "-p", f"{e.port}:{e.port}",
            "-e", f"HF_TOKEN={token}",
            "-e", f"HUGGING_FACE_HUB_TOKEN={token}",
            "-e", "HF_HOME=/root/.cache/huggingface",
            "-v", f"{hf_home()}:/root/.cache/huggingface",
            "--label", "miniclosedai.manager=1",
            "--label", f"miniclosedai.served={e.served_name}",
            "--label", f"miniclosedai.port={e.port}",
            "--label", f"miniclosedai.hf_id={e.hf_id}",
            "--entrypoint", "vllm", image,
            "serve", *self._vllm_args(e),
        ]
        inner = " ".join(shlex.quote(x) for x in run_argv)
        script = (
            f"echo '== ensuring image {image} (first run downloads several GB; reused after) =='\n"
            f"docker pull {shlex.quote(image)} 2>&1\n"
            f"docker rm -f {shlex.quote(name)} >/dev/null 2>&1 || true\n"
            f"echo '== starting container =='\n"
            f"if {inner}; then echo '== container started =='; "
            f"else echo 'MANAGER-ERROR: docker run failed (see messages above)'; fi\n"
        )
        logf = self._log(e).open("wb")
        subprocess.Popen(["bash", "-c", script], stdout=logf,
                         stderr=subprocess.STDOUT, start_new_session=True)

    def stop(self, e: ModelEntry) -> None:
        _run(["docker", "rm", "-f", self.container(e)], timeout=60)

    def is_alive(self, e: ModelEntry) -> bool:
        return self._inspect_status(e) == "running"

    def recent_logs(self, e: ModelEntry, lines: int = 60) -> str:
        if self._inspect_status(e) is not None:
            r = _run(["docker", "logs", "--tail", str(lines), self.container(e)], timeout=15)
            return (r.stdout or "") + (r.stderr or "")
        p = self._log(e)
        return "\n".join(p.read_text(errors="replace").splitlines()[-lines:]) if p.exists() else ""

    def open_log_stream(self, e: ModelEntry) -> subprocess.Popen | None:
        if self._inspect_status(e) is not None:
            return subprocess.Popen(
                ["docker", "logs", "-f", "--tail", "400", self.container(e)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        self._log(e).touch(exist_ok=True)
        return subprocess.Popen(
            ["tail", "-n", "400", "-F", str(self._log(e))],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

    def discover(self) -> list[dict]:
        fmt = ('{{.Names}}\t{{.Label "miniclosedai.served"}}\t'
               '{{.Label "miniclosedai.port"}}\t{{.Label "miniclosedai.hf_id"}}\t{{.State}}')
        r = _run(["docker", "ps", "-a", "--filter", "label=miniclosedai.manager=1",
                  "--format", fmt], timeout=15)
        out = []
        for line in (r.stdout or "").splitlines():
            cols = line.split("\t")
            if len(cols) >= 5 and cols[4] == "running":
                out.append({"served": cols[1], "port": int(cols[2] or 0), "hf_id": cols[3]})
        return out


class NativeEngine(Engine):
    name = "native"

    def _meta(self, e: ModelEntry) -> Path:
        return RUN_DIR / f"{e.served_name}.json"

    def _log(self, e: ModelEntry) -> Path:
        return RUN_DIR / f"{e.served_name}.log"

    def available(self) -> tuple[bool, str]:
        if shutil.which("vllm"):
            return True, "vllm CLI found"
        try:
            __import__("vllm")
            return True, "vllm importable"
        except Exception:
            return False, "vLLM not installed (pip install vllm) in this environment"

    def launch(self, e: ModelEntry) -> None:
        RUN_DIR.mkdir(exist_ok=True)
        vllm = shutil.which("vllm")
        cmd = [vllm, "serve", *self._vllm_args(e)] if vllm \
            else ["python", "-m", "vllm.entrypoints.cli.main", "serve", *self._vllm_args(e)]
        logf = self._log(e).open("wb")
        env = dict(os.environ)
        token = _env("HF_TOKEN")
        if token:
            env["HF_TOKEN"] = token
            env["HUGGING_FACE_HUB_TOKEN"] = token
        proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT,
                                start_new_session=True, env=env)
        self._meta(e).write_text(json.dumps(
            {"pid": proc.pid, "port": e.port, "served": e.served_name,
             "hf_id": e.hf_id, "engine": self.name}))

    def _pid(self, e: ModelEntry) -> int | None:
        try:
            return int(json.loads(self._meta(e).read_text())["pid"])
        except Exception:
            return None

    def stop(self, e: ModelEntry) -> None:
        pid = self._pid(e)
        if pid:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(os.getpgid(pid), sig)
                except ProcessLookupError:
                    break
                except OSError:
                    break
                time.sleep(0.5)
                if not self._alive_pid(pid):
                    break
        self._meta(e).unlink(missing_ok=True)

    @staticmethod
    def _alive_pid(pid: int) -> bool:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def is_alive(self, e: ModelEntry) -> bool:
        pid = self._pid(e)
        return bool(pid and self._alive_pid(pid))

    def state(self, e: ModelEntry) -> str:
        pid = self._pid(e)
        if pid is None:
            return "absent"
        return "running" if self._alive_pid(pid) else "exited"

    def recent_logs(self, e: ModelEntry, lines: int = 60) -> str:
        p = self._log(e)
        if not p.exists():
            return ""
        data = p.read_text(errors="replace").splitlines()
        return "\n".join(data[-lines:])

    def open_log_stream(self, e: ModelEntry) -> subprocess.Popen | None:
        RUN_DIR.mkdir(exist_ok=True)
        self._log(e).touch(exist_ok=True)
        return subprocess.Popen(
            ["tail", "-n", "400", "-F", str(self._log(e))],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        )

    def discover(self) -> list[dict]:
        out = []
        if not RUN_DIR.is_dir():
            return out
        for meta in RUN_DIR.glob("*.json"):
            try:
                d = json.loads(meta.read_text())
            except Exception:
                continue
            if d.get("pid") and self._alive_pid(int(d["pid"])):
                out.append({"served": d.get("served", meta.stem),
                            "port": int(d.get("port", 0)), "hf_id": d.get("hf_id", ""),
                            "engine": d.get("engine", self.name)})
        return out


class ShimEngine(NativeEngine):
    """Serve any HF model bare-metal via the transformers shim (shim/server.py).

    The engine that reliably works on a plain gaming PC with no Docker daemon
    and no pip-installed vLLM. Inherits NativeEngine's pid-file/log/state/
    stop/discover machinery; the shim is OpenAI-compatible (`/v1/models` +
    `/v1/chat/completions`) so readiness probing works unchanged.
    """
    name = "shim"

    def available(self) -> tuple[bool, str]:
        py = shim_python()
        if py:
            return True, f"transformers shim: {py}"
        return False, "transformers shim not set up — run ./setup_shim.sh"

    def launch(self, e: ModelEntry) -> None:
        RUN_DIR.mkdir(exist_ok=True)
        py = shim_python()
        if not py:
            raise RuntimeError("transformers shim not set up; run ./setup_shim.sh")
        cmd = [py, str(ROOT / "shim" / "server.py")]

        env = dict(os.environ)
        env["SHIM_MODEL_ID"] = e.hf_id
        env["SHIM_SERVED_NAME"] = e.served_name
        env["SHIM_PORT"] = str(e.port)
        env["SHIM_MODALITY"] = "vlm" if e.multimodal else "text"
        env["SHIM_TRUST_REMOTE_CODE"] = "1" if e.params.get("trust_remote_code") else "0"
        if e.params.get("max_images"):
            env["SHIM_MAX_IMAGES"] = str(e.params["max_images"])
        key = _env("VLLM_API_KEY")
        if key:
            env["SHIM_API_KEY"] = key
        token = _env("HF_TOKEN")
        if token:
            env["HF_TOKEN"] = token
            env["HUGGING_FACE_HUB_TOKEN"] = token

        logf = self._log(e).open("wb")
        proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT,
                                start_new_session=True, env=env)
        self._meta(e).write_text(json.dumps(
            {"pid": proc.pid, "port": e.port, "served": e.served_name,
             "hf_id": e.hf_id, "engine": self.name}))


# --------------------------------------------------------------------------- manager
class Manager:
    def __init__(self) -> None:
        self.entries: dict[str, ModelEntry] = {}
        self.docker = DockerEngine()
        self.native = NativeEngine()
        self.shim = ShimEngine()
        self._add_lock = threading.Lock()

    # ---- engine selection -------------------------------------------------
    @property
    def engine(self) -> Engine:
        """Which engine new launches use. Re-derived on every access instead
        of cached once at startup — a background ./setup_shim.sh that
        finishes after the manager boots is picked up on the very next
        launch, no restart required."""
        return self._select_engine()

    def _select_engine(self) -> Engine:
        choice = _env("LAUNCH_ENGINE", "auto").lower()
        if choice == "docker":
            return self.docker
        if choice == "native":
            return self.native
        if choice == "shim":
            return self.shim
        # auto: docker (if reachable) -> native vLLM (if installed) -> the
        # bare-metal transformers shim. On a typical node (no Docker, no
        # pip-installed vLLM by design) the shim is the one that actually runs.
        if self.docker.available()[0]:
            return self.docker
        if self.native.available()[0]:
            return self.native
        if self.shim.available()[0]:
            return self.shim
        return self.docker  # degraded; surfaced via engine_info()

    def engine_info(self) -> dict:
        d_ok, d_msg = self.docker.available()
        n_ok, n_msg = self.native.available()
        s_ok, s_msg = self.shim.available()
        shim_build = shim_build_status()
        if not s_ok and shim_build["building"]:
            s_msg = f"installing shim… {shim_build['progress']}".rstrip()
        gpu = gpu_info()
        return {
            "engine": self.engine.name,
            "engine_override": _env("LAUNCH_ENGINE", "auto"),
            "docker_ok": d_ok, "docker_msg": d_msg,
            "native_ok": n_ok, "native_msg": n_msg,
            "shim_ok": s_ok, "shim_msg": s_msg,
            "shim_building": shim_build["building"], "shim_progress": shim_build["progress"],
            "gpu_ok": bool(gpu.get("gpus")),
            "image": vllm_image(),
            "hf_home": hf_home(),
            "runpod": bool(_env("RUNPOD_POD_ID")),
            "lan_ip": lan_ip(),
            "no_engine": not (d_ok or n_ok or s_ok),
        }

    gpu_info = staticmethod(gpu_info)

    # ---- persistence ------------------------------------------------------
    def load(self) -> None:
        if STATE_FILE.exists():
            try:
                data = json.loads(STATE_FILE.read_text())
                for d in data.get("models", []):
                    e = ModelEntry.from_dict(d)
                    self.entries[e.id] = e
            except Exception:
                pass

    def save(self) -> None:
        STATE_FILE.write_text(json.dumps(
            {"version": STATE_VERSION,
             "models": [e.to_dict() for e in self.entries.values()]}, indent=2))

    def reconcile(self) -> None:
        """Load registry, re-attach to live instances."""
        self.load()
        live = {}
        for d in self.docker.discover() + self.native.discover():
            live.setdefault(d["served"], d)
        for e in self.entries.values():
            if e.served_name in live:
                d = live[e.served_name]
                e.desired_state = "running"
                e.engine = d.get("engine") or e.engine or self.engine.name
                if d.get("port"):
                    e.port = d["port"]
            elif e.desired_state == "running":
                e.desired_state = "stopped"
        for served, d in live.items():
            if not any(e.served_name == served for e in self.entries.values()):
                self.entries[served] = ModelEntry(
                    id=served, hf_id=d.get("hf_id", "") or "(unknown)",
                    served_name=served, port=d.get("port") or 0,
                    desired_state="running", engine=d.get("engine") or self.engine.name,
                    created_at=_now())
        self.save()

    # ---- allocation -------------------------------------------------------
    def _unique_served(self, base: str) -> str:
        name, i = base, 2
        existing = {e.served_name for e in self.entries.values()}
        while name in existing:
            name = f"{base}-{i}"
            i += 1
        return name

    def next_free_port(self, start: int = PORT_START) -> int:
        used = {e.port for e in self.entries.values()}
        p = start
        while p in used or not _port_is_free(p):
            p += 1
        return p

    # ---- CRUD + lifecycle -------------------------------------------------
    def add(self, hf_id: str, served_name: str | None = None,
            port: int | None = None, params: dict | None = None,
            run: bool = True, force: bool = False) -> ModelEntry:
        hf_id = normalize_hf_id(hf_id)

        report = analyze_model(hf_id)
        if not report.get("exists"):
            raise ValueError(report.get("error", "model not found on HuggingFace"))
        if not report.get("supported", True):
            raise ValueError(
                f"{hf_id} is a GGUF-only repo — this node has no GGUF/llama.cpp "
                "engine. Pick a safetensors repo instead."
            )
        if not force and report.get("fits") is False and report.get("need_gb"):
            err = ValueError(
                f"{hf_id} needs ~{report['need_gb']} GB but only "
                f"{report['available_gb']} GB is free. Pass force to run anyway, "
                f"or pick a smaller / quantized model.")
            err.analysis = report  # type: ignore[attr-defined]
            raise err

        merged = dict(PARAM_DEFAULTS)
        merged.update(params or {})
        multimodal = bool(report.get("multimodal"))

        # Cap max_model_len to the model's native context — asking vLLM/the
        # shim for more than the model supports can abort startup.
        if not (params or {}).get("max_model_len") and report.get("max_ctx"):
            merged["max_model_len"] = min(int(merged["max_model_len"]), int(report["max_ctx"]))
        # Size gpu_memory_util from FREE capacity, not total.
        if not (params or {}).get("gpu_memory_util") and report.get("total_gb"):
            avail, total = report["available_gb"], report["total_gb"]
            if total:
                merged["gpu_memory_util"] = max(0.30, round(min(0.90, avail * 0.85 / total), 2))
        if not multimodal:
            if not (params or {}).get("max_images"):
                merged["max_images"] = None
            merged.setdefault("mm_processor_kwargs", None)
        _validate_params(merged)

        with self._add_lock:
            dup = next((x for x in self.entries.values()
                        if x.hf_id == hf_id and x.desired_state != "stopped"), None)
            if dup is not None:
                raise ValueError(
                    f"{hf_id} is already running as '{dup.served_name}' on port "
                    f"{dup.port}. Stop it first to launch another copy.")
            served = slugify(served_name) if served_name else slugify(hf_id.split("/")[-1])
            served = self._unique_served(served)
            if port is None:
                port = self.next_free_port()
            elif any(x.port == port for x in self.entries.values()):
                raise ValueError(f"port {port} is already assigned to another model")
            e = ModelEntry(id=served, hf_id=hf_id, served_name=served, port=port,
                           params=merged, engine=self.engine.name,
                           desired_state="running" if run else "stopped",
                           multimodal=multimodal, size_gb=report.get("size_gb") or 0.0,
                           created_at=_now())
            self.entries[e.id] = e
            self.save()
        if run:
            self.start(e.id)
        return e

    def get(self, mid: str) -> ModelEntry:
        if mid not in self.entries:
            raise KeyError(mid)
        return self.entries[mid]

    def start(self, mid: str) -> ModelEntry:
        e = self.get(mid)
        eng = self._engine_for(e)
        ok, msg = eng.available()
        if not ok:
            e.error = f"launch engine '{eng.name}' unavailable: {msg}"
            e.desired_state = "stopped"
            self.save()
            raise RuntimeError(e.error)
        e.error = ""
        try:
            eng.launch(e)
            e.desired_state = "running"
            e.engine = eng.name
        except Exception as exc:
            e.error = str(exc)[-2000:]
            e.desired_state = "stopped"
            self.save()
            raise
        self.save()
        return e

    def stop(self, mid: str) -> ModelEntry:
        e = self.get(mid)
        self._engine_for(e).stop(e)
        e.desired_state = "stopped"
        self.save()
        return e

    def remove(self, mid: str) -> None:
        e = self.get(mid)
        try:
            self.stop(mid)
        except Exception:
            pass
        del self.entries[mid]
        self.save()

    # ---- status + views ---------------------------------------------------
    def _engine_for(self, e: ModelEntry) -> Engine:
        if e.engine == "docker":
            return self.docker
        if e.engine == "native":
            return self.native
        if e.engine == "shim":
            return self.shim
        return self.engine

    @staticmethod
    def _scan_error(logs: str) -> str | None:
        low = logs.lower()
        markers = ("out of memory", "manager-error", "no matching manifest",
                   "401 client error", "403 client error", "gatedrepoerror",
                   "repositorynotfounderror", "traceback (most recent call last)",
                   "error response from daemon")
        return next((m for m in markers if m in low), None)

    def derive_status(self, e: ModelEntry) -> dict:
        eng = self._engine_for(e)
        st = eng.state(e)

        if st == "running":
            ready, ids = probe_models(e.port)
            if ready:
                return {"status": "ready", "ready": True, "detail": ", ".join(ids)}
            logs = eng.recent_logs(e, 100)
            if self._scan_error(logs):
                tail = eng.recent_logs(e, 40)
                return {"status": "error", "ready": False, "detail": tail,
                        "needs_hf_token": is_gated_auth_error(logs)}
            low = logs.lower()
            if not is_cached(e.hf_id) and any(
                    k in low for k in ("downloading", "fetching", "resolving data")):
                status = "downloading"
            else:
                status = "loading"
            return {"status": status, "ready": False, "detail": ""}

        if st == "exited":
            tail = eng.recent_logs(e, 40)
            detail = tail or e.error or "exited"
            return {"status": "error", "ready": False, "detail": detail,
                    "needs_hf_token": is_gated_auth_error(detail)}

        if e.desired_state == "running":
            logs = eng.recent_logs(e, 100)
            if self._scan_error(logs) or e.error:
                detail = logs or e.error
                return {"status": "error", "ready": False, "detail": detail,
                        "needs_hf_token": is_gated_auth_error(detail)}
            phase = "pulling" if eng.name == "docker" else "starting"
            return {"status": phase, "ready": False, "detail": ""}
        if e.error:
            return {"status": "error", "ready": False, "detail": e.error[-1200:],
                    "needs_hf_token": is_gated_auth_error(e.error)}
        return {"status": "stopped", "ready": False, "detail": ""}

    def base_url(self, e: ModelEntry, public: bool = True) -> str:
        """URL to register with the interdata relay.

        - not public -> 127.0.0.1 (local-only checks).
        - RunPod      -> the pod's public proxy URL.
        - otherwise   -> PUBLIC_HOST (install.sh sets this to the node's own
                        tailnet IP — the SAME address its Ollama backend
                        registered with) or the LAN IP as a last resort.
        """
        if not public:
            return f"http://127.0.0.1:{e.port}/v1"
        host_override = _env("PUBLIC_HOST") or _env("ADVERTISE_HOST")
        pod = _env("RUNPOD_POD_ID")
        if pod and not host_override:
            return f"https://{pod}-{e.port}.proxy.runpod.net/v1"
        return f"http://{host_override or lan_ip() or 'localhost'}:{e.port}/v1"

    def view(self, e: ModelEntry) -> dict:
        st = self.derive_status(e)
        return {
            **e.to_dict(),
            "status": st["status"],
            "ready": st["ready"],
            "detail": st["detail"],
            "needs_hf_token": st.get("needs_hf_token", False),
            "error": e.error,
            "base_url": self.base_url(e),
            "local_url": self.base_url(e, public=False),
        }

    def list_views(self) -> list[dict]:
        return [self.view(e) for e in sorted(self.entries.values(), key=lambda x: x.served_name)]

    def open_log_stream(self, mid: str) -> subprocess.Popen | None:
        e = self.get(mid)
        return self._engine_for(e).open_log_stream(e)


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _validate_params(p: dict) -> None:
    for jf in ("mm_processor_kwargs", "hf_overrides"):
        v = p.get(jf)
        if v:
            try:
                json.loads(v)
            except (TypeError, ValueError) as exc:
                raise ValueError(f"{jf} must be valid JSON: {exc}")
    if not (0.1 <= float(p["gpu_memory_util"]) <= 1.0):
        raise ValueError("gpu_memory_util must be between 0.1 and 1.0")
    if int(p["max_model_len"]) < 256:
        raise ValueError("max_model_len too small")
    if isinstance(p.get("extra_args"), str):
        p["extra_args"] = p["extra_args"].split()
