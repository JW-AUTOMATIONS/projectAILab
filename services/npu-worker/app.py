"""OpenAI-compatible embeddings + speech-to-text served from the Intel NPU.

Endpoints:
  GET  /health                    -> which device each pipeline actually landed on
  GET  /v1/models
  POST /v1/embeddings             -> {"input": str | [str], "model": ...}
  POST /v1/audio/transcriptions   -> multipart: file=<audio>, model=..., language=...

Each pipeline is compiled for the first device in its *_DEVICES list that
works (default "NPU,CPU"), so the service still comes up when the NPU user-space
driver is missing - /health tells you which device was used.
"""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
import tempfile
import threading
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel

log = logging.getLogger("npu-worker")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))

MODELS_DIR = Path(os.getenv("MODELS_DIR", "/models"))
OV_CACHE_DIR = os.getenv("OV_CACHE_DIR", str(MODELS_DIR / ".ov-cache"))

EMBED_MODEL = os.getenv("EMBED_MODEL", "BAAI/bge-base-en-v1.5")
EMBED_MODEL_NAME = os.getenv("EMBED_MODEL_NAME", "embed")
EMBED_DEVICES = os.getenv("EMBED_DEVICES", "NPU,CPU")
EMBED_POOLING = os.getenv("EMBED_POOLING", "cls").upper()
EMBED_MAX_LENGTH = int(os.getenv("EMBED_MAX_LENGTH", "512"))
EMBED_QUERY_INSTRUCTION = os.getenv("EMBED_QUERY_INSTRUCTION", "")

STT_MODEL = os.getenv("STT_MODEL", "openai/whisper-base")
STT_MODEL_NAME = os.getenv("STT_MODEL_NAME", "whisper")
STT_DEVICES = os.getenv("STT_DEVICES", "NPU,CPU")

SAMPLE_RATE = 16_000


# --------------------------------------------------------------------------- #
# Model resolution: local dir -> HF snapshot -> optimum-cli export to OpenVINO IR
# --------------------------------------------------------------------------- #
def _is_ov_dir(path: Path) -> bool:
    return any(path.glob("openvino_*model*.xml"))


def resolve_model(ref: str, export_task: str) -> Path:
    """Return a directory containing an OpenVINO IR export of `ref`.

    `ref` is either an existing directory or a Hugging Face repo id. Repos that
    already ship OpenVINO IR (e.g. the `OpenVINO/*-ov` org) are used as-is;
    anything else is converted once with `optimum-cli export openvino`.
    """
    local = Path(ref)
    if local.is_dir():
        if not _is_ov_dir(local):
            raise RuntimeError(f"{local} exists but contains no OpenVINO IR")
        return local

    target = MODELS_DIR / ref.replace("/", "--")
    if target.is_dir() and _is_ov_dir(target):
        return target

    from huggingface_hub import snapshot_download

    snap = Path(snapshot_download(ref))
    if _is_ov_dir(snap):
        return snap

    if shutil.which("optimum-cli") is None:
        raise RuntimeError(
            f"{ref} is not in OpenVINO IR format and optimum-cli is not installed; "
            "rebuild the image with WITH_EXPORTER=1 or point the env var at an *-ov repo"
        )
    log.info("exporting %s to OpenVINO IR (%s) -> %s", ref, export_task, target)
    tmp = target.parent / (target.name + ".partial")
    shutil.rmtree(tmp, ignore_errors=True)
    subprocess.run(
        ["optimum-cli", "export", "openvino", "--model", str(snap),
         "--task", export_task, "--weight-format", "fp16", str(tmp)],
        check=True,
    )
    shutil.rmtree(target, ignore_errors=True)
    tmp.rename(target)
    return target


def _first_working(devices: str, build):
    errors = []
    for device in [d.strip() for d in devices.split(",") if d.strip()]:
        try:
            pipe = build(device)
            log.info("compiled on %s", device)
            return pipe, device
        except Exception as exc:  # noqa: BLE001 - OpenVINO raises bare RuntimeError
            log.warning("device %s failed: %s", device, exc)
            errors.append(f"{device}: {exc}")
    raise RuntimeError("no usable device: " + "; ".join(errors))


# --------------------------------------------------------------------------- #
# Pipelines (loaded lazily, one at a time, guarded by a lock each)
# --------------------------------------------------------------------------- #
class Embedder:
    def __init__(self) -> None:
        import openvino_genai as ov_genai

        path = resolve_model(EMBED_MODEL, "feature-extraction")
        pooling = ov_genai.TextEmbeddingPipeline.PoolingType.__members__[EMBED_POOLING]

        def build(device: str):
            cfg = ov_genai.TextEmbeddingPipeline.Config()
            cfg.pooling_type = pooling
            cfg.normalize = True
            cfg.max_length = EMBED_MAX_LENGTH
            if EMBED_QUERY_INSTRUCTION:
                cfg.query_instruction = EMBED_QUERY_INSTRUCTION
            if device == "NPU":
                # The NPU compiler needs fully static shapes.
                cfg.pad_to_max_length = True
                cfg.batch_size = 1
            return ov_genai.TextEmbeddingPipeline(path, device, cfg, CACHE_DIR=OV_CACHE_DIR)

        self.pipe, self.device = _first_working(EMBED_DEVICES, build)
        self.lock = threading.Lock()

    def embed(self, texts: list[str]) -> list[list[float]]:
        with self.lock:
            if self.device == "NPU":  # batch_size is pinned to 1 on NPU
                return [list(self.pipe.embed_documents([t])[0]) for t in texts]
            return [list(v) for v in self.pipe.embed_documents(texts)]


class Transcriber:
    def __init__(self) -> None:
        import openvino_genai as ov_genai

        path = resolve_model(STT_MODEL, "automatic-speech-recognition-with-past")
        self.pipe, self.device = _first_working(
            STT_DEVICES, lambda d: ov_genai.WhisperPipeline(path, d, CACHE_DIR=OV_CACHE_DIR)
        )
        self.lock = threading.Lock()

    def transcribe(self, pcm: np.ndarray, language: str | None) -> str:
        kwargs: dict[str, Any] = {"task": "transcribe", "return_timestamps": False}
        if language:
            kwargs["language"] = f"<|{language}|>"
        with self.lock:
            result = self.pipe.generate(pcm.tolist(), **kwargs)
        return result.texts[0].strip()


def decode_audio(data: bytes) -> np.ndarray:
    """Any container/codec ffmpeg understands -> mono float32 @ 16 kHz."""
    with tempfile.NamedTemporaryFile() as src:
        src.write(data)
        src.flush()
        proc = subprocess.run(
            ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", src.name,
             "-f", "f32le", "-ac", "1", "-ar", str(SAMPLE_RATE), "-"],
            capture_output=True,
        )
    if proc.returncode != 0:
        raise HTTPException(400, f"could not decode audio: {proc.stderr.decode()[:300]}")
    return np.frombuffer(proc.stdout, dtype=np.float32)


# --------------------------------------------------------------------------- #
# HTTP layer
# --------------------------------------------------------------------------- #
_pipes: dict[str, Any] = {}
_pipes_lock = threading.Lock()


def get_pipe(kind: str):
    with _pipes_lock:
        if kind not in _pipes:
            try:
                _pipes[kind] = Embedder() if kind == "embed" else Transcriber()
            except Exception as exc:  # surface load failures as 503, retry next call
                log.exception("failed to load %s pipeline", kind)
                raise HTTPException(503, f"{kind} pipeline unavailable: {exc}") from exc
        return _pipes[kind]


@asynccontextmanager
async def lifespan(_: FastAPI):
    if os.getenv("PRELOAD", "1") == "1":
        for kind in ("embed", "stt"):
            try:
                await run_in_threadpool(get_pipe, kind)
            except HTTPException:
                pass  # already logged; /health reports it
    yield


app = FastAPI(title="npu-worker", lifespan=lifespan)


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "embed": getattr(_pipes.get("embed"), "device", None),
        "stt": getattr(_pipes.get("stt"), "device", None),
    }


@app.get("/v1/models")
def models() -> dict[str, Any]:
    return {
        "object": "list",
        "data": [
            {"id": EMBED_MODEL_NAME, "object": "model", "owned_by": "npu-worker"},
            {"id": STT_MODEL_NAME, "object": "model", "owned_by": "npu-worker"},
        ],
    }


class EmbeddingRequest(BaseModel):
    input: str | list[str]
    model: str | None = None
    encoding_format: str | None = "float"


@app.post("/v1/embeddings")
def embeddings(req: EmbeddingRequest) -> dict[str, Any]:
    texts = [req.input] if isinstance(req.input, str) else req.input
    if not texts:
        raise HTTPException(400, "input must not be empty")
    vectors = get_pipe("embed").embed(texts)
    return {
        "object": "list",
        "model": EMBED_MODEL_NAME,
        "data": [{"object": "embedding", "index": i, "embedding": v} for i, v in enumerate(vectors)],
        "usage": {"prompt_tokens": 0, "total_tokens": 0},
    }


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: str | None = Form(None),
    language: str | None = Form(None),
    response_format: str = Form("json"),
):
    pcm = await run_in_threadpool(decode_audio, await file.read())
    if pcm.size == 0:
        raise HTTPException(400, "audio is empty")
    stt = await run_in_threadpool(get_pipe, "stt")
    text = await run_in_threadpool(stt.transcribe, pcm, language)
    if response_format == "text":
        return PlainTextResponse(text)
    return {"text": text}
