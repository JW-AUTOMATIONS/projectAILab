# projectAILab

A local AI workstation stack for **Intel Core Ultra 9 185H + NVIDIA RTX 5060 Ti +
96 GB DDR5**. Each piece of silicon gets the work it is best at:

* **RTX 5060 Ti + DDR5:** the main model. llama.cpp (CUDA sm_120) keeps
  attention and KV on the GPU and MoE experts in RAM, pinned to the P-cores.
* **Arc iGPU:** a small helper model (llama.cpp Vulkan) for titles, tags,
  query rewriting and tool-output summaries.
* **AI Boost NPU:** RAG embeddings and Whisper speech-to-text (OpenVINO GenAI).
* **E-cores:** Open WebUI and AnythingLLM. The LP E-cores are left to the OS.

The design, the sizing table and a fact-check of the original report are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Install

On a fresh **Ubuntu 24.04 LTS** (Server or Desktop):

```bash
git clone https://github.com/JW-AUTOMATIONS/projectAILab.git && cd projectAILab
./install.sh --dry-run      # optional: shows every change without making it
sudo ./install.sh           # drivers, docker, storage, tuning, images, service
sudo reboot                 # the stack starts by itself afterwards
sudo /opt/ailab/install.sh verify
```

The installer sets up the HWE kernel and the NVIDIA open driver (≥ 570,
signed modules). It also installs the Intel GPU compute/media/Vulkan stack,
the Intel NPU driver and firmware, Docker plus the NVIDIA Container Toolkit,
the optional data NVMe and LACP bond, CPU/power tuning, and the
`ailab.service` systemd unit. Every stage is idempotent and can be re-run on
its own.

**[docs/INSTALL.md](docs/INSTALL.md)** covers the full walkthrough: BIOS
settings, Ubuntu install choices, configuration (`install.conf.example`),
day-to-day operations and troubleshooting.

When it's running:

* Open WebUI: `http://<host>:3000`. Models `main` and `aux` appear
  automatically. RAG embeddings and the microphone button use the NPU.
* AnythingLLM: add `COMPOSE_PROFILES=anythingllm` with `ailab edit`, then open
  `http://<host>:3001`.
* `ailab status | logs <svc> | bench | check | edit | update`

## Layout

```
install.sh, installer/        staged, idempotent host installer (see docs/INSTALL.md)
install.conf.example          installer settings
compose.yaml                  services, device passthrough, cpusets
.env.example                  model choices and tunables (installer writes .env)
docker/llama-cuda/            llama.cpp built for Blackwell (CUDA 12.8, sm_120)
services/npu-worker/          OpenAI-compatible embeddings + STT on the NPU
host/scripts/check-host.sh    preflight: drivers, devices, firmware, PCIe link, bond
host/scripts/gen-env.sh       detects P/E/LP-E cpusets, Intel render node, render GID
host/netplan/60-bond0.yaml    reference LACP bond (the installer generates its own)
scripts/ailab                 day-2 CLI, installed as /usr/local/bin/ailab
scripts/bench.sh              prompt/generation t/s of the running servers
```

## Tuning

Pick a model and a `MAIN_N_CPU_MOE` value, then measure:

```bash
ailab edit                  # MAIN_MODEL_ARGS / MAIN_N_CPU_MOE
ailab bench 8081 2048 256
ailab status                # VRAM used/total
```

Lower `MAIN_N_CPU_MOE` (more expert layers on the GPU) until VRAM is about 90%
used, then re-run the bench. `.env.example` lists presets for 8 GB and 16 GB
cards, dense 70 B models, and the largest MoE that fits.

## Development

```bash
cd services/npu-worker
pip install -r requirements.txt pytest httpx
pytest -q          # HTTP layer tests with fake pipelines; ffmpeg needed for STT tests
```
