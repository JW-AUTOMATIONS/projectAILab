# shellcheck shell=bash
# Arc iGPU: compute runtime (Level Zero / OpenCL), media, Vulkan and tools.
#
# The containers bring their own Mesa/Vulkan user space; the host packages are
# for diagnostics (vulkaninfo, clinfo, intel_gpu_top) and provide the Level Zero
# loader that the NPU driver also needs.

stage_intel_gpu() {
  if [[ -n $INTEL_GPU_PPA ]]; then
    # add-apt-repository writes a .sources file whose URI contains "<owner>/<ppa>".
    if ! grep -rqs "${INTEL_GPU_PPA#ppa:}" /etc/apt/sources.list.d/; then
      run add-apt-repository -y --no-update "$INTEL_GPU_PPA"
    fi
    apt_update
  fi

  apt_install_available \
    libze1 libze-intel-gpu1 intel-opencl-icd intel-metrics-discovery intel-gsc \
    intel-media-va-driver-non-free libvpl2 libmfx-gen1 va-driver-all vainfo \
    mesa-vulkan-drivers vulkan-tools clinfo intel-gpu-tools

  add_user_to_groups render video
  ok "Intel GPU stack installed"
}
