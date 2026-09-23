"""HTTP-layer tests with fake pipelines (no NPU or model download needed).

    pip install -r requirements.txt pytest httpx && pytest -q
"""

import os
import shutil
import subprocess

import pytest

os.environ["PRELOAD"] = "0"

import app  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402


class FakeEmbedder:
    device = "NPU"

    def embed(self, texts):
        return [[float(len(t)), 0.0] for t in texts]


class FakeTranscriber:
    device = "NPU"

    def __init__(self):
        self.calls = []

    def transcribe(self, pcm, language):
        self.calls.append((pcm.size, language))
        return "hello from the npu"


@pytest.fixture
def client(monkeypatch):
    stt = FakeTranscriber()
    monkeypatch.setattr(app, "_pipes", {"embed": FakeEmbedder(), "stt": stt})
    with TestClient(app.app) as c:
        c.stt = stt
        yield c


def test_embeddings_single_and_batch(client):
    r = client.post("/v1/embeddings", json={"input": "abc", "model": "embed"})
    assert r.status_code == 200
    assert r.json()["data"] == [{"object": "embedding", "index": 0, "embedding": [3.0, 0.0]}]

    r = client.post("/v1/embeddings", json={"input": ["a", "bb"]})
    assert [d["embedding"][0] for d in r.json()["data"]] == [1.0, 2.0]


def test_embeddings_rejects_empty(client):
    assert client.post("/v1/embeddings", json={"input": []}).status_code == 400


def test_health_reports_devices(client):
    assert client.get("/health").json() == {"embed": "NPU", "stt": "NPU"}


def test_load_failure_is_503(monkeypatch):
    monkeypatch.setattr(app, "_pipes", {})
    monkeypatch.setattr(app, "EMBED_MODEL", "/definitely/not/a/model")
    with TestClient(app.app) as c:
        r = c.post("/v1/embeddings", json={"input": "x"})
    assert r.status_code == 503


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_transcription_decodes_audio(client, tmp_path):
    wav = tmp_path / "tone.wav"
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
         "-ar", "44100", "-ac", "2", str(wav)],
        check=True,
    )
    with wav.open("rb") as f:
        r = client.post("/v1/audio/transcriptions", files={"file": ("tone.wav", f)},
                        data={"model": "whisper", "language": "en"})
    assert r.status_code == 200
    assert r.json() == {"text": "hello from the npu"}
    samples, language = client.stt.calls[0]
    assert samples == pytest.approx(16_000, abs=200)  # resampled to 16 kHz mono
    assert language == "en"


def test_transcription_rejects_garbage(client):
    if shutil.which("ffmpeg") is None:
        pytest.skip("ffmpeg not installed")
    r = client.post("/v1/audio/transcriptions", files={"file": ("x.wav", b"not audio")})
    assert r.status_code == 400

