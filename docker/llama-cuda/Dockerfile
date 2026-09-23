# llama.cpp built for the RTX 5060 Ti (Blackwell, compute capability 12.0).
#
# Blackwell needs CUDA >= 12.8 to generate sm_120 code, so build from source
# instead of relying on whatever arch list a prebuilt image happens to ship.
ARG CUDA_VERSION=12.8.1
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS build

# Pin to a release tag (e.g. b6500) once you have a known-good build.
ARG LLAMA_CPP_REF=master
ARG CUDA_ARCH=120

RUN apt-get update && apt-get install -y --no-install-recommends \
        git cmake build-essential libcurl4-openssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/ggml-org/llama.cpp /src \
    && git -C /src checkout "${LLAMA_CPP_REF}"

WORKDIR /src
# GGML_NATIVE=OFF + explicit AVX2/AVX-VNNI: the image is built for the 185H
# (no AVX-512) and must not pick up the build machine's ISA.
RUN cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
        -DGGML_NATIVE=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_AVX_VNNI=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DLLAMA_CURL=ON \
        -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build -j"$(nproc)" --target llama-server llama-bench llama-cli

FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4t64 libgomp1 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/build/bin/llama-server /src/build/bin/llama-bench /src/build/bin/llama-cli /usr/local/bin/

ENV LLAMA_CACHE=/root/.cache/llama.cpp
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=30m \
    CMD curl -fsS http://localhost:8080/health || exit 1
ENTRYPOINT ["llama-server"]
