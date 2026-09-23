# Installing the AI Lab

From bare metal to a running stack in four steps:

1. Firmware settings
2. Install Ubuntu 24.04 LTS
3. Run `install.sh`
4. Reboot and verify

The installer handles drivers (NVIDIA, Intel GPU, NPU), Docker, the NVIDIA
Container Toolkit, storage, networking, tuning, the container images, and a
systemd service that starts the stack at boot.

---

## 1. Firmware (BIOS/UEFI) settings

Before installing, set these in firmware setup:

| Setting | Value | Why |
|---|---|---|
| Integrated graphics / "iGPU multi-monitor" | **Enabled** | Many boards turn the iGPU off when a dGPU is present. The Arc iGPU runs the helper model and drives the desktop. |
| Intel NPU / "AI Boost" / "VPU" | **Enabled** | Embeddings and speech-to-text run on it. |
| Above 4G decoding | **Enabled** | Needed for Resizable BAR. |
| Resizable BAR | **Enabled** | Lets the CPU map all VRAM, which helps expert offload. |
| Primary display | **iGPU / onboard** | Keeps VRAM free for models. |
| Memory profile | DDR5-5600 (XMP/JEDEC) | Decode speed of RAM-resident experts scales with memory bandwidth. |
| Secure Boot | Either | Ubuntu's NVIDIA modules are signed, so no MOK enrollment is needed. |
| Restore on AC power loss | Power On | Server behaviour. |

If the RTX 5060 Ti is attached through OCuLink or a dock, make sure it is
powered on **before** the machine boots.

Plug monitors into the **motherboard** outputs, not the NVIDIA card.

## 2. Install Ubuntu 24.04 LTS

Use **Ubuntu Server 24.04 LTS** (recommended, headless) or Ubuntu Desktop
24.04. The installer supports both. Download the latest 24.04.x ISO from
ubuntu.com and write it to a USB stick (balenaEtcher, Rufus or `dd`).

During setup:

* **Disk:** install to one NVMe (the first Crucial P3 Plus). Leave the second
  NVMe **untouched**; the installer can format it for models (see
  `MODELS_DISK`). The default "use entire disk" with LVM is fine. Ubuntu only
  gives the root LV about 100 GB of the disk; when models stay on the OS disk,
  the installer grows root to use the rest.
* **Network:** plug in one I226-V port and use DHCP. Bonding comes later.
* **Profile:** create your own user, not `root`.
* **SSH:** tick "Install OpenSSH server" so you can finish over SSH.
* **Snaps / third-party drivers:** skip them all. The installer installs the
  correct NVIDIA driver itself.

After the first boot, log in and update the system once:

```bash
sudo apt update && sudo apt -y full-upgrade && sudo reboot
```

## 3. Run the installer

Get the repository onto the machine. It's private, so use a GitHub personal
access token or `gh auth login`:

```bash
sudo apt install -y git
git clone https://github.com/JW-AUTOMATIONS/projectAILab.git ~/projectAILab
cd ~/projectAILab
```

Optionally copy the settings file and edit it:

```bash
cp install.conf.example install.conf
nano install.conf
```

The settings you are most likely to change:

| Setting | Default | Change it when |
|---|---|---|
| `MODELS_DISK` | empty (models on the OS disk) | You want the second NVMe for models and docker. Use `/dev/disk/by-id/nvme-CT1000P3PSSD8_…`. **That disk is erased.** |
| `BOND_ENABLE` | `0` | Your switch supports LACP on two ports. Otherwise set `BOND_MODE=active-backup`. |
| `NVIDIA_DRIVER_BRANCH` | `auto` | You need a specific branch, for example `580`. |
| `CPU_EPP` | `performance` | The box runs hot. Use `balance_performance` instead. |
| `HF_TOKEN` | empty | You want gated Hugging Face models. |

Preview the changes, then run the installer:

```bash
./install.sh --dry-run        # shows every package, file and command; changes nothing
sudo ./install.sh             # takes 20-60 min, most of it the CUDA llama.cpp build
```

If you set `MODELS_DISK`, it asks you to type the disk name before erasing it.
For unattended runs, use `WIPE_MODELS_DISK=1`. Everything is logged to
`/var/log/ailab-install.log`.

## 4. Reboot and verify

The installer ends with a list of the reasons a reboot is needed (new kernel,
NVIDIA driver). Reboot:

```bash
sudo reboot
```

`ailab.service` starts the stack automatically after boot. The first start
downloads the models, about 63 GB for gpt-oss-120b plus about 3 GB for the
helper model. Follow the download with `ailab logs llm-main`. Then check
everything:

```bash
sudo /opt/ailab/install.sh verify      # or: ailab check
```

`verify` runs the host preflight (drivers, firmware, PCIe link, bond). It then
checks that CUDA works inside a container and hits every service's health
endpoint. Open WebUI is at `http://<machine-ip>:3000`; the first account you
create becomes the admin.

---

## What the installer does

| Stage | What it changes |
|---|---|
| `preflight` | Nothing. Checks the OS, CPU, GPU, NPU and iGPU on PCI, Secure Boot, internet reachability and free space. |
| `base` | `apt full-upgrade`, the HWE kernel + headers, admin tools (`nvtop`, `btop`, `lm-sensors`, `nvme-cli`, `hwloc`, `linux-tools`), OpenSSH. |
| `nvidia` | The newest open NVIDIA branch ≥ 570 that `ubuntu-drivers` recommends, with Canonical-signed prebuilt modules (DKMS only as a fallback). `nvidia-persistenced`. Excludes the driver from unattended upgrades. On a desktop install, `prime-select on-demand`. |
| `intel-gpu` | Intel graphics PPA, Level Zero, OpenCL, media (VA-API/VPL), Mesa Vulkan, `intel_gpu_top`. Adds the user to `render` and `video`. |
| `npu` | Intel NPU user-mode driver, compiler and firmware from `intel/linux-npu-driver`. A udev rule gives `/dev/accel/accel0` to `render`. Reloads `intel_vpu` and records the driver version for the container. |
| `storage` | `DATA_ROOT` (`/srv/ai`) for models. Without `MODELS_DISK`, grows an LVM root to fill its volume group. With `MODELS_DISK` set, the disk gets a GPT, ext4 labelled `ailab-data`, and an `fstab` entry with `nofail`. |
| `docker` | Docker Engine and the Compose plugin from download.docker.com, plus the NVIDIA Container Toolkit. `daemon.json` gets log rotation and a data-root on `DATA_ROOT`. Adds the user to `docker`. |
| `network` | With `BOND_ENABLE=1`, writes `/etc/netplan/60-ailab-bond.yaml` for the two I226-V ports and disables cloud-init network rewriting. |
| `tuning` | `vm.swappiness=10`, a larger `vm.max_map_count`, CPU EPP applied at every boot (`ailab-tune.service`), suspend masked. |
| `stack` | Copies the repo to `/opt/ailab`. Writes `.env`: cpusets, render node and GID, WebUI secret, model preset by VRAM, and the llama.cpp and NPU driver versions pinned. Pulls and builds the images, then installs and enables `ailab.service` and the `ailab` command. |

Every stage is idempotent. Re-run any of them at any time:

```bash
sudo ./install.sh nvidia        # e.g. after changing NVIDIA_DRIVER_BRANCH
sudo ./install.sh network       # after changing the BOND_* settings
```

## Day-to-day

```bash
ailab status              # containers, health, VRAM/temps, NPU device, RAM
ailab logs llm-main       # follow one service
ailab bench               # prompt/generation tokens per second, main and aux
ailab edit                # edit /opt/ailab/.env and apply it
ailab restart llm-main
ailab update              # git pull, rebuild llama.cpp at the newest release, restart
```

To change the main model, run `ailab edit` and set `MAIN_MODEL_ARGS` and
`MAIN_N_CPU_MOE`. Presets are in the comments. See
[ARCHITECTURE.md](ARCHITECTURE.md) for sizing.

To update the OS and drivers deliberately (the driver is kept out of
unattended upgrades):

```bash
sudo apt update && sudo apt full-upgrade && sudo reboot
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `nvidia-smi`: "Driver/library version mismatch" | The driver was updated without a reboot. Reboot. |
| `nvidia-smi`: "No devices were found" | Check the card is seen (`lspci -d 10de:`), then check the eGPU power and cable, then `sudo dmesg \| grep -i nvrm`. A "requires open kernel modules" message means a non-open branch was installed; re-run `sudo ./install.sh nvidia`. |
| NVIDIA module won't load, Secure Boot on (DKMS fallback only) | Run `sudo update-secureboot-policy --enroll-key` and set a one-time password. Reboot, choose "Enroll MOK" on the blue screen, and enter that password. |
| `llm-main` exits with CUDA out of memory | Raise `MAIN_N_CPU_MOE` or lower `MAIN_CTX` (`ailab edit`). |
| `llm-main` very slow | Run `ailab bench`. Check `nvidia-smi` shows about 90% VRAM used, and check the PCIe link in `ailab check`. Stop `llm-aux` while benchmarking, since it shares memory bandwidth. |
| `npu-worker` `/health` shows `"CPU"` | Check `ls -l /dev/accel/accel0` (group `render`) and `dmesg \| grep -i vpu` for firmware errors, then re-run `sudo ./install.sh npu && ailab restart npu-worker`. |
| `llm-aux` fails to find a Vulkan device | Confirm `INTEL_RENDER_NODE` in `.env` points at the Intel node (`ls -l /sys/class/drm/renderD*/device/driver`), then re-run `sudo ./install.sh stack`. |
| Lost network after enabling the bond | Use the local console. `sudo rm /etc/netplan/60-ailab-bond.yaml && sudo netplan apply` restores the original config. |
| GitHub API rate limit during install | Set `GITHUB_TOKEN` (a read-only personal token) in `install.conf`. |
| `required variable ... is missing a value` from compose | Re-run `sudo ./install.sh stack`; it regenerates the host-specific values in `.env`. |

## Removing it

```bash
sudo systemctl disable --now ailab.service ailab-tune.service
cd /opt/ailab && sudo docker compose down -v      # -v also deletes Open WebUI/AnythingLLM data
sudo rm -rf /opt/ailab /etc/systemd/system/ailab*.service /usr/local/bin/ailab /usr/local/sbin/ailab-tune \
  /etc/sysctl.d/90-ailab.conf /etc/udev/rules.d/10-intel-vpu.rules /etc/apt/apt.conf.d/51ailab-nvidia-hold \
  /etc/netplan/60-ailab-bond.yaml /var/lib/ailab
# Model files live under /srv/ai/models. Drivers and docker stay installed.
```
