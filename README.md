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

## Layout

```
compose.yaml                  services, device passthrough, cpusets
.env.example                  model choices and tunables
docker/llama-cuda/            llama.cpp built for Blackwell (CUDA 12.8, sm_120)
services/npu-worker/          OpenAI-compatible embeddings + STT on the NPU
host/scripts/check-host.sh    preflight: drivers, devices, firmware, PCIe link, bond
host/scripts/gen-env.sh       detects P/E/LP-E cpusets, Intel render node, render GID
host/netplan/60-bond0.yaml    2× I226-V LACP bond
scripts/bench.sh              prompt/generation t/s of the running servers
```

## Host prerequisites (Ubuntu 24.04)

1. Kernel 6.8 or newer (the 24.04 HWE kernel is fine).
2. NVIDIA driver **570 or newer, open kernel modules**, for example
   `sudo ubuntu-drivers install --gpgpu nvidia:570-server-open` or a newer
   `-open` branch.
3. Docker Engine and the
   [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html),
   then run `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`.
4. NPU firmware on the host: `intel-fw-npu` from
   [intel/linux-npu-driver](https://github.com/intel/linux-npu-driver/releases),
   or a recent `linux-firmware`. Also add the udev rule in
   [ARCHITECTURE.md](docs/ARCHITECTURE.md#device-passthrough) if
   `/dev/accel/accel0` isn't in the `render` group.
5. Optional: set up the network bond from `host/netplan/60-bond0.yaml`. Edit
   the interface names first.

## Quick start

```bash
host/scripts/check-host.sh                # fix any FAIL lines first
cp .env.example .env
host/scripts/gen-env.sh --write .env      # cpusets, render node/GID, WebUI secret
docker compose build                      # llama.cpp CUDA + npu-worker images
docker compose up -d
docker compose logs -f llm-main           # first start downloads the model (~63 GB)
```

* Open WebUI: `http://<host>:3000`. Models `main` and `aux` appear
  automatically. RAG embeddings and the microphone button use the NPU.
* AnythingLLM: `docker compose --profile anythingllm up -d`, then open
  `http://<host>:3001`.
* NPU status: `curl localhost:8083/health` returns `{"embed": "NPU", "stt": "NPU"}`
  (or `"CPU"` if it fell back).

## Tuning

Pick a model and a `MAIN_N_CPU_MOE` value, then measure:

```bash
docker compose up -d llm-main && scripts/bench.sh 8081 2048 256
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
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
