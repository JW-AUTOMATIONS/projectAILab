# Architecture

Target machine: Intel Core Ultra 9 185H (6P + 8E + 2 LP-E, 22 threads, Arc iGPU,
AI Boost NPU) · NVIDIA RTX 5060 Ti · 96 GB DDR5 · 2× Crucial P3 Plus 1 TB
(CT1000P3PSSD8) · 2× Intel I226-V 2.5 GbE · Intel BE200 Wi-Fi 7.

This repo implements the design from the original "Heterogeneous Local AI
Workstation" report, with the corrections listed in
[Corrections to the source report](#corrections-to-the-source-report).

## Silicon map

| Unit | Service | Work | Pinned to |
|---|---|---|---|
| RTX 5060 Ti + DDR5 | `llm-main` (llama.cpp, CUDA sm_120) | Main chat and reasoning model. MoE attention and KV live on the GPU, expert FFNs in RAM (`--n-cpu-moe`). | P-cores (`MAIN_CPUSET`) |
| Arc iGPU | `llm-aux` (llama.cpp, Vulkan) | Small helper model: titles, tags, query rewriting, summarising tool output | E-cores (`AUX_CPUSET`) |
| AI Boost NPU | `npu-worker` (OpenVINO GenAI) | `/v1/embeddings` for RAG, `/v1/audio/transcriptions` (Whisper) | E-cores |
| CPU E-cores | `open-webui`, `anythingllm` | UI, RAG pipeline, vector DB | E-cores |
| LP E-cores | host OS | Left free for the OS, SSH and docker | — |

```
LAN (bond0, 2×2.5 GbE LACP)
   │
   ├── :3000 open-webui ──┬── llm-main  :8081  (5060 Ti + DDR5, P-cores)
   └── :3001 anythingllm ─┤── llm-aux   :8082  (Arc iGPU, Vulkan)
                          └── npu-worker:8083  (NPU: embeddings + Whisper)
```

The model APIs (8081-8083) bind to `127.0.0.1` by default. Only the UIs are
exposed on the LAN. To expose the APIs to Dify or other hosts, set `BIND_ADDR`.

## Why llama.cpp `--n-cpu-moe` rather than ktransformers by default

The report's central idea is correct: for MoE models, keep attention, shared
experts and the KV cache on the GPU, and run the sparse routed experts on the
CPU from system RAM. In 2025, llama.cpp added exactly this as `--n-cpu-moe N`,
which is shorthand for `-ot` tensor overrides that pin `ffn_*_exps` to the CPU.
That puts the same placement strategy on the most widely supported engine, with
GGUF quantisations for every current model and an OpenAI-compatible server.

ktransformers is still worth trying for models it has tuned kernels for. It has
no service here because:

* Its headline target, DeepSeek-V3/R1 671B, does not fit on this box (see below).
* It moves quickly and has its own CUDA and kernel build requirements, and
  Blackwell (sm_120) support should be confirmed for the version you pick.

### Sizing on 96 GB + 16 GB

Decode speed for CPU-resident experts is roughly bounded by
`DDR5 bandwidth / bytes of active expert weights per token`. DDR5-5600 dual
channel gives 89.6 GB/s peak, and about 60-70 GB/s in practice.

| Model | Size | Active/token | Fits? | Expected decode |
|---|---|---|---|---|
| gpt-oss-120b (MXFP4) | ~63 GB | ~5.1 B | Yes, with room for the aux model | ~15-25 t/s |
| Qwen3-30B-A3B Q4_K_M | ~18 GB | ~3.3 B | Yes, even on an 8 GB card | 30+ t/s |
| GLM-4.5-Air Q4_K_M | ~70 GB | ~12 B | Yes, tight | ~8-12 t/s |
| Qwen3-235B-A22B ~2.5 bpw | ~85-95 GB | ~22 B | Only with `llm-aux` stopped | ~3-6 t/s |
| Llama 3.3 70B Q4_K_M (dense) | ~42 GB | 70 B | Yes, with layer split (`MAIN_NGL`) | ~2 t/s |
| DeepSeek-V3/R1 671B | ≥131 GB at 1.58-bit | 37 B | **No** | — |

These are planning estimates, not measurements. Use `scripts/bench.sh` on the
real hardware and tune `MAIN_N_CPU_MOE`: lower it until VRAM is about 90% used.

## CPU pinning

`host/scripts/gen-env.sh` classifies CPUs from sysfs:

* **P-cores:** listed in `/sys/devices/cpu_core/cpus`.
* **E-cores:** listed in `cpu_atom` and have an L3 (compute tile).
* **LP E-cores:** listed in `cpu_atom` with no L3 (SoC tile).

Compose applies `cpuset` from these values. `llm-main` gets the P-cores, with
one decode thread per physical core (`MAIN_THREADS=6`) and both hyperthreads
for batch/prefill (`MAIN_THREADS_BATCH=12`). Everything else goes on the
E-cores, so helper work doesn't preempt decode threads. This replaces the
`taskset`/`numactl` approach in the report and survives container restarts.

## Shared memory bandwidth: the main caveat

The CPU, Arc iGPU and NPU all read from the **same** DDR5 memory controller.
Moving embeddings or a helper LLM onto the iGPU or NPU frees P-core cycles and
GPU VRAM. It does **not** free memory bandwidth, and bandwidth is what limits
decode speed for CPU-offloaded experts. If `llm-aux` generates while `llm-main`
is decoding a MoE model from RAM, both slow down. Practical consequences:

* Keep the aux model small (3-4 B). Use it for short, bursty tasks.
* Embedding ingestion on the NPU is fine interactively. For bulk ingestion of
  large libraries, schedule it when the main model is idle.
* For benchmarks, measure `llm-main` with `llm-aux` idle.

## Device passthrough

| Device | Compose | Notes |
|---|---|---|
| RTX 5060 Ti | `deploy.resources.reservations.devices: [{driver: nvidia, capabilities: [gpu]}]` | Needs the NVIDIA Container Toolkit, **driver ≥ 570 with the open kernel modules** (a Blackwell requirement), and CUDA ≥ 12.8 in the image. No `video` group is needed. |
| Arc iGPU | `devices: [${INTEL_RENDER_NODE}:/dev/dri/renderD128]` + `group_add: [${RENDER_GID}]` | With the NVIDIA driver loaded there are two render nodes. `gen-env.sh` picks the one with PCI vendor `0x8086` instead of assuming `renderD128`. |
| NPU | `devices: [/dev/accel/accel0]` + `group_add: [${RENDER_GID}]` | Kernel `intel_vpu` driver and NPU firmware on the host. Level Zero plus the NPU user-mode driver ([intel/linux-npu-driver](https://github.com/intel/linux-npu-driver)) inside the image. Keep `NPU_DRIVER_TAG` compatible with the host firmware. |

If `/dev/accel/accel0` is owned by `root:root`, add a udev rule:

```
# /etc/udev/rules.d/10-intel-vpu.rules
SUBSYSTEM=="accel", KERNEL=="accel*", GROUP="render", MODE="0660"
```

## NPU worker

`services/npu-worker` is a small FastAPI app that exposes OpenAI-compatible
`/v1/embeddings` and `/v1/audio/transcriptions`. Both run through OpenVINO
GenAI's `TextEmbeddingPipeline` and `WhisperPipeline`.

* It compiles each pipeline on the first working device in `*_DEVICES`
  (default `NPU,CPU`). A missing NPU driver degrades to CPU (E-cores) instead
  of failing. `GET /health` shows which device each pipeline landed on.
* On the NPU, embeddings use static shapes (`pad_to_max_length`,
  `batch_size=1`), which the NPU compiler requires.
* Hugging Face repos that are not already OpenVINO IR are exported once with
  `optimum-cli` and cached under `MODELS_DIR/openvino`. The compiled NPU blobs go
  in `OV_CACHE_DIR`, so first-inference latency is only paid once.

## Networking

`host/netplan/60-bond0.yaml` bonds the two I226-V ports with 802.3ad LACP and a
`layer3+4` hash. It needs a switch with LACP on both ports. LACP hashes per
flow, so one client never gets more than 2.5 Gb/s. What the bond really buys is
failover, plus headroom for model downloads and concurrent RAG uploads. Token
streaming is a few KB/s, so the network is never the inference bottleneck.

## Dify

Dify's own compose file runs about ten services, so it isn't vendored here.
Deploy it from [langgenius/dify](https://github.com/langgenius/dify) and add
two "OpenAI-API-compatible" model providers:

* `http://<host>:8081/v1`, model `main`: heavy reasoning.
* `http://<host>:8082/v1`, model `aux`: cheap parsing and summarisation steps.

Add `http://<host>:8083/v1`, model `embed`, as the embedding provider. Set
`BIND_ADDR=0.0.0.0` (or the bond0 IP) so Dify can reach these ports.

## Corrections to the source report

| Report says | Correction | Effect on this repo |
|---|---|---|
| RTX 5060 Ti uses GDDR6 | It uses **GDDR7** (448 GB/s, 128-bit), PCIe 5.0 **x8** | Weight-transfer cost is higher on narrow links. `check-host.sh` reports link width and warns on OCuLink/TB-style x4 links. |
| (unstated) Blackwell software support | Needs driver ≥ 570 with **open kernel modules**, and CUDA ≥ 12.8 for sm_120 | `docker/llama-cuda` builds with CUDA 12.8 and `CMAKE_CUDA_ARCHITECTURES=120`. |
| ktransformers can run DeepSeek-V3 671B on this box | Even the 1.58-bit dynamic quant is about 131 GB, more than 96 + 16 GB | Default is gpt-oss-120b. The sizing table above lists realistic models. |
| KV cache "grows exponentially" with context | It grows **linearly** with context length. MLA shrinks the per-token constant. | — |
| Offloading to the iGPU/NPU "preserves the primary memory bandwidth" | The iGPU, NPU and CPU share one DDR5 controller | See [Shared memory bandwidth](#shared-memory-bandwidth-the-main-caveat). Aux work is pinned to E-cores. |
| Arc iGPU: 20-30 t/s on 7-8 B models | Q4 8 B is about 4.7 GB/token and bandwidth is about 60-70 GB/s effective, so expect **~10-15 t/s** | Aux default is a 4 B model. |
| Vulkan "built into most Linux kernels" | Vulkan is user-space (Mesa ANV). The kernel side is i915/xe DRM. | The prebuilt `server-vulkan` image ships Mesa. |
| SYCL vs Vulkan concurrency table | Directionally plausible but version-dependent. Benchmark rather than assume. | Vulkan is used (simpler image, no oneAPI). The SYCL image is `server-intel`. |
| NPU needs kernel ≥ 6.8 | `intel_vpu` has been mainline since 6.3. 6.8+ is a sensible floor for Meteor Lake. It also needs **firmware on the host and the user-mode driver in the container**. | `npu-worker` image installs the UMD. `check-host.sh` checks firmware. |
| NVIDIA group permission `video` | Not needed with the NVIDIA Container Toolkit | — |
| `ggerganov/llama.cpp` | Moved to `ggml-org/llama.cpp` | — |
| Crucial P3 1 TB (CT1000P3PSSD8) | That part number is the **P3 Plus** (PCIe 4.0, up to 5 GB/s read). Both NVMe and AirLLM layer streaming are far slower than RAM. | AirLLM not included: every model that fits on NVMe but not in RAM is too slow to use interactively. mmap from NVMe is the fallback. |
| `Khaeldur/overflowml` sizes offload automatically | Could not verify this project | Not used. Tune `MAIN_N_CPU_MOE` / `MAIN_NGL` with `scripts/bench.sh`. |
| `intel/ipex-llm` for the iGPU | Intel has wound down IPEX/ipex-llm development in favour of upstream PyTorch XPU and OpenVINO. Check its status before adopting. | llama.cpp Vulkan for the iGPU, OpenVINO for the NPU. |
| Aggregated 5 Gb/s link prevents I/O saturation from inference output | See [Networking](#networking) | Bonding kept for failover. |
