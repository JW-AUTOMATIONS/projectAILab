# NPU worker: OpenVINO GenAI embeddings + Whisper on the Intel AI Boost NPU.
#
# The host supplies the kernel driver (intel_vpu) and NPU firmware; the container
# needs the matching user-space pieces: the Level Zero loader and Intel's NPU
# UMD/compiler from https://github.com/intel/linux-npu-driver. Keep NPU_DRIVER_TAG
# in step with the firmware installed on the host (see docs/ARCHITECTURE.md).
FROM ubuntu:24.04

ARG NPU_DRIVER_TAG=latest
ARG LEVEL_ZERO_TAG=latest
# 1 = also install optimum-intel + CPU torch so non-OpenVINO HF repos are
# converted on first start. 0 = smaller image; point *_MODEL at *-ov repos.
ARG WITH_EXPORTER=1

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    OPENVINO_TELEMETRY_DISABLE=1 \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq ffmpeg libtbb12 python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Level Zero loader + NPU user-mode driver. Release assets have been shipped both
# as loose .debs and as a tarball of .debs, so accept either.
RUN set -eux; \
    fetch_assets() { \
        repo="$1"; tag="$2"; pattern="$3"; \
        if [ "$tag" = latest ]; then api="https://api.github.com/repos/$repo/releases/latest"; \
        else api="https://api.github.com/repos/$repo/releases/tags/$tag"; fi; \
        curl -fsSL "$api" | jq -r '.assets[].browser_download_url' | grep -E "$pattern" \
            | while read -r url; do curl -fsSLO "$url"; done; \
    }; \
    mkdir /tmp/drv && cd /tmp/drv; \
    fetch_assets intel/level-zero "$LEVEL_ZERO_TAG" 'level-zero_[^/]*u24\.04_amd64\.deb$'; \
    fetch_assets intel/linux-npu-driver "$NPU_DRIVER_TAG" '(ubuntu24\.?04[^/]*\.deb|ubuntu2404[^/]*\.tar\.gz)$'; \
    for t in *.tar.gz; do [ -e "$t" ] && tar -xzf "$t"; done; \
    # intel-fw-npu is host-side firmware; the container only needs the user-space libs.
    find . -name '*.deb' ! -name 'intel-fw-npu*' -print0 | xargs -0 apt-get install -y --no-install-recommends; \
    ls /usr/lib/x86_64-linux-gnu | grep -E 'libze_(loader|intel_npu)' ; \
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
