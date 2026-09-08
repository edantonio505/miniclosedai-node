#!/usr/bin/env python3
"""miniclosedai-node — HuggingFace model manager control plane.

A trimmed, CLI-only sibling of miniclosedai-llm's web control plane: no
static GUI (this node has no browser dashboard — see the `mcai-node` CLI in
the repo root), no models.yaml/profile system (launch whatever hf_id you
give it), no GGUF/llama.cpp engine. Downloads + serves a HuggingFace model
behind an OpenAI `/v1` API (vLLM via Docker/native, or the bare-metal
transformers shim), with live status/logs and a base_url the node's own CLI
registers with the interdata relay.

Heavy lifting (CUDA/torch/vLLM) runs inside the launched container/
subprocess; this app only orchestrates via model_manager. Binds
0.0.0.0:MANAGER_PORT (default 8099).
"""
from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

import model_manager as mm

ROOT = Path(__file__).resolve().parent
API_KEY = mm._env("MANAGER_API_KEY")
PORT = int(mm._env("MANAGER_PORT", "8099"))
VERSION = "1.0.0"

manager = mm.Manager()


def _require_auth(authorization: str | None = Header(None)) -> None:
    if not API_KEY:
        return
    if authorization != f"Bearer {API_KEY}":
        raise HTTPException(401, "Invalid or missing Authorization header.")


app = FastAPI(title="miniclosedai-node model manager", docs_url="/docs", redoc_url=None)


@app.on_event("startup")
async def _startup() -> None:
    await asyncio.to_thread(manager.reconcile)


# --------------------------------------------------------------------------- schemas
class AddModelRequest(BaseModel):
    hf_id: str
    served_name: str | None = None
    port: int | None = None
    params: dict | None = None
    run: bool = True
    force: bool = False


class AnalyzeRequest(BaseModel):
    hf_id: str


class HFTokenRequest(BaseModel):
    token: str


# --------------------------------------------------------------------------- meta
@app.get("/api/health")
async def health(_=Depends(_require_auth)):
    info = await asyncio.to_thread(manager.engine_info)
    info["manager_port"] = PORT
    return {"ok": True, "version": VERSION, **info}


@app.get("/api/gpu")
async def gpu(_=Depends(_require_auth)):
    return await asyncio.to_thread(manager.gpu_info)


@app.post("/api/analyze")
async def analyze(req: AnalyzeRequest, _=Depends(_require_auth)):
    return await asyncio.to_thread(mm.analyze_model, req.hf_id)


@app.get("/api/hf-token")
async def hf_token_get(_=Depends(_require_auth)):
    return await asyncio.to_thread(mm.hf_token_status)


@app.post("/api/hf-token")
async def hf_token_set(req: HFTokenRequest, _=Depends(_require_auth)):
    res = await asyncio.to_thread(mm.set_hf_token, req.token)
    if not res.get("ok"):
        raise HTTPException(400, res.get("error", "could not set token"))
    return res


@app.delete("/api/hf-token")
async def hf_token_clear(_=Depends(_require_auth)):
    await asyncio.to_thread(mm.clear_hf_token)
    return {"ok": True}


@app.get("/api/cache")
async def cache(_=Depends(_require_auth)):
    models = await asyncio.to_thread(mm.list_cached_models)
    return {"models": models, "hf_home": mm.hf_home(),
            "total_gb": round(sum(m["size_gb"] for m in models), 1)}


class CacheDeleteRequest(BaseModel):
    hf_id: str


@app.post("/api/cache/delete")
async def cache_delete(req: CacheDeleteRequest, _=Depends(_require_auth)):
    removed = await asyncio.to_thread(mm.delete_cached_model, req.hf_id)
    if not removed:
        raise HTTPException(404, "not found in cache")
    return {"ok": True}


# --------------------------------------------------------------------------- models CRUD
@app.get("/api/models")
async def list_models(_=Depends(_require_auth)):
    return {"models": await asyncio.to_thread(manager.list_views)}


@app.post("/api/models", status_code=201)
async def add_model(req: AddModelRequest, _=Depends(_require_auth)):
    try:
        e = await asyncio.to_thread(
            manager.add, req.hf_id, req.served_name, req.port, req.params,
            req.run, req.force)
    except ValueError as exc:
        analysis = getattr(exc, "analysis", None)
        if analysis is not None:
            raise HTTPException(409, {"message": str(exc), "analysis": analysis})
        raise HTTPException(400, str(exc))
    except RuntimeError as exc:
        raise HTTPException(503, str(exc))
    return await asyncio.to_thread(manager.view, e)


@app.post("/api/models/{mid}/start")
async def start_model(mid: str, _=Depends(_require_auth)):
    try:
        e = await asyncio.to_thread(manager.start, mid)
    except KeyError:
        raise HTTPException(404, "no such model")
    except RuntimeError as exc:
        raise HTTPException(503, str(exc))
    return await asyncio.to_thread(manager.view, e)


@app.post("/api/models/{mid}/stop")
async def stop_model(mid: str, _=Depends(_require_auth)):
    try:
        e = await asyncio.to_thread(manager.stop, mid)
    except KeyError:
        raise HTTPException(404, "no such model")
    return await asyncio.to_thread(manager.view, e)


@app.delete("/api/models/{mid}")
async def delete_model(mid: str, _=Depends(_require_auth)):
    try:
        await asyncio.to_thread(manager.remove, mid)
    except KeyError:
        raise HTTPException(404, "no such model")
    return {"ok": True}


@app.get("/api/models/{mid}/status")
async def model_status(mid: str, _=Depends(_require_auth)):
    try:
        e = manager.get(mid)
    except KeyError:
        raise HTTPException(404, "no such model")
    return await asyncio.to_thread(manager.derive_status, e)


# --------------------------------------------------------------------------- logs (SSE)
@app.get("/api/models/{mid}/logs")
async def model_logs(mid: str, request: Request, _=Depends(_require_auth)):
    try:
        entry = manager.get(mid)
    except KeyError:
        raise HTTPException(404, "no such model")

    async def gen():
        try:
            proc = await asyncio.to_thread(manager.open_log_stream, mid)
        except Exception as exc:
            yield _sse({"eof": True, "detail": str(exc)})
            return
        if proc is None:
            yield _sse({"eof": True, "detail": "no log stream available"})
            return
        q: asyncio.Queue = asyncio.Queue(maxsize=2000)
        loop = asyncio.get_running_loop()
        SENTINEL = object()

        def _pump():
            try:
                for line in proc.stdout:  # type: ignore[union-attr]
                    asyncio.run_coroutine_threadsafe(q.put(("line", line.rstrip("\n"))), loop)
            finally:
                asyncio.run_coroutine_threadsafe(q.put(SENTINEL), loop)

        worker = asyncio.create_task(asyncio.to_thread(_pump))
        last_probe = 0.0
        try:
            st = await asyncio.to_thread(manager.derive_status, entry)
            yield _sse({"status": st["status"], "ready": st["ready"]})
            while True:
                if await request.is_disconnected():
                    break
                try:
                    item = await asyncio.wait_for(q.get(), timeout=2.0)
                except asyncio.TimeoutError:
                    item = None
                if item is SENTINEL:
                    yield _sse({"eof": True})
                    break
                if item is not None:
                    yield _sse({"line": item[1]})
                now = time.monotonic()
                if now - last_probe > 2.0:
                    last_probe = now
                    st = await asyncio.to_thread(manager.derive_status, entry)
                    yield _sse({"status": st["status"], "ready": st["ready"],
                                "needs_hf_token": st.get("needs_hf_token", False)})
        finally:
            try:
                proc.terminate()
            except Exception:
                pass
            worker.cancel()

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no"})


def _sse(obj: dict) -> str:
    return f"data: {json.dumps(obj)}\n\n"


@app.exception_handler(Exception)
async def _unhandled(request: Request, exc: Exception):  # pragma: no cover
    return JSONResponse(status_code=500, content={"detail": str(exc)})


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="0.0.0.0", port=PORT, log_level="info")
