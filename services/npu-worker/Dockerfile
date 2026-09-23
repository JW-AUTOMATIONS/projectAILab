# NPU worker: OpenVINO GenAI embeddings + Whisper on the Intel AI Boost NPU.
#
# The host supplies the kernel driver (intel_vpu) and NPU firmware; the container
# needs the matching user-space pieces: the Level Zero loader (Intel PPA) and
# Intel's NPU UMD/compiler from https://github.com/intel/linux-npu-driver. install.sh pins
# NPU_DRIVER_TAG to the release it installed on the host, so both sides match.
FROM ubuntu:24.04

ARG NPU_DRIVER_TAG=latest
# Same PPA as the host (install.sh intel-gpu stage) so both use one Level Zero.
ARG INTEL_GPU_PPA=ppa:kobuk-team/intel-graphics
# 1 = also install optimum-intel + CPU torch so non-OpenVINO HF repos are
# converted on first start. 0 = smaller image; point *_MODEL at *-ov repos.
ARG WITH_EXPORTER=1

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    OPENVINO_TELEMETRY_DISABLE=1 \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq ffmpeg libtbb12 python3 python3-venv software-properties-common \
    && add-apt-repository -y "$INTEL_GPU_PPA" \
    && apt-get install -y --no-install-recommends libze1 \
    && rm -rf /var/lib/apt/lists/*

# NPU user-mode driver + compiler. Releases have shipped both loose .debs and a
# tarball of .debs, so accept either. intel-fw-npu is firmware for the host
# kernel, not needed in the container.
RUN set -eux; \
    if [ "$NPU_DRIVER_TAG" = latest ]; then api=https://api.github.com/repos/intel/linux-npu-driver/releases/latest; \
    else api="https://api.github.com/repos/intel/linux-npu-driver/releases/tags/$NPU_DRIVER_TAG"; fi; \
    mkdir /tmp/drv && cd /tmp/drv; \
    curl -fsSL --retry 3 "$api" | jq -r '.assets[].browser_download_url' \
        | grep -E 'ubuntu[._-]?24\.?04[^/]*\.(deb|tar\.gz)$' | grep -v dbgsym > urls; \
    test -s urls; \
    while read -r url; do curl -fsSLO --retry 3 "$url"; done < urls; \
    for t in *.tar.gz; do if [ -e "$t" ]; then tar -xzf "$t"; fi; done; \
    apt-get update; \
    find . -name '*.deb' ! -name 'intel-fw-npu*' ! -name '*dbgsym*' -print0 \
        | xargs -0 apt-get install -y --no-install-recommends; \
    ls /usr/lib/x86_64-linux-gnu | grep -E 'libze_intel_(npu|vpu)'; \
    cd / && rm -rf /tmp/drv /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt \
    && if [ "$WITH_EXPORTER" = 1 ]; then \
        pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch \
        && pip install --no-cache-dir "optimum-intel[openvino]"; \
    fi

WORKDIR /app
COPY app.py /app/app.py

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10m \
    CMD curl -fsS http://localhost:8000/health || exit 1
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
