# HotAisle GPU VM Deployment Tools

A collection of bash scripts for automating the deployment and management of GPU virtual machines on the HotAisle cloud platform, specifically configured for running large language models (LLMs) via Ollama.

## Overview

This project provides a streamlined workflow for:
- **Provisioning** GPU VMs on HotAisle (AMD MI300X)
- **Deploying** Ollama with the `gpt-oss:120b` model
- **Managing** VM lifecycle (provision, deploy, destroy)

The scripts handle the entire pipeline from VM creation to model serving, including SSH setup, Docker configuration, and model downloads.

## Scripts

### `deploy_and_run.sh` - Main Deployment Script

The primary script that orchestrates the entire deployment process.

**Features:**
- Optionally provisions a new HotAisle VM (if no IP provided)
- Extracts SSH IP from HotAisle API response
- Cleans SSH host keys for seamless reconnection
- Uploads startup script to the remote VM
- Runs remote setup with progress indicators
- Opens separate terminal window for Ollama logs
- Displays comprehensive timing statistics

**Usage:**
```bash
# Provision new VM and deploy
./deploy_and_run.sh

# Deploy to existing VM
./deploy_and_run.sh <GPU_IP_ADDRESS>
```

**Environment Variables:**
- `HOTAISLE_TEAM_NAME` - Your HotAisle team name (required for provisioning)
- `HOTAISLE_TOKEN` - HotAisle API authentication token (required for provisioning)
- `HOTAISLE_USER_DATA_URL` - Optional cloud-init user-data URL
- `REMOTE_USER` - SSH username for remote VM (default: `hotaisle`)

**What it does:**
1. Provisions VM with AMD MI300X GPU (13 CPU cores, 240GB RAM, 12TB disk)
2. Waits for SSH connectivity
3. Uploads `startup-amd.sh` to the VM
4. Executes remote setup (Docker, Ollama, model pull)
5. Opens Ollama logs in new terminal
6. Displays timing summary

### `destroy_vm.sh` - VM Deletion Script

Deletes a HotAisle VM by name via the API.

**Usage:**
```bash
./destroy_vm.sh <vm-name>
```

**Example:**
```bash
./destroy_vm.sh enc1-gpuvm028
```

**Environment Variables:**
- `HOTAISLE_TEAM_NAME` - Your HotAisle team name (required)
- `HOTAISLE_TOKEN` - HotAisle API authentication token (required)

**Features:**
- Validates HTTP 204 response for successful deletion
- Displays error details if deletion fails
- Clear success/failure messaging

### `startup-amd.sh` - AMD GPU Setup Script

Configures Ollama on AMD GPUs using ROCm. This script is uploaded to and executed on the remote VM.

**Features:**
- Installs Docker if not present
- Pulls Ollama ROCm image (`ollama/ollama:rocm`)
- Configures GPU access via `/dev/kfd` and `/dev/dri`
- Pulls `gpt-oss:120b` model
- Exposes OpenAI-compatible API endpoint

**Environment Variables:**
- `MODEL_NAME` - Model to pull (default: `gpt-oss:120b`)
- `OLLAMA_IMAGE` - Ollama Docker image (default: `ollama/ollama:rocm`)
- `DATA_DIR` - Data directory (default: `/opt/ollama`)
- `PORT` - API port (default: `11434`)

**Target:** AMD MI300X GPUs with ROCm support

### `startup-nvidia.sh` - NVIDIA GPU Setup Script

Configures Ollama on NVIDIA GPUs. Similar to `startup-amd.sh` but uses NVIDIA GPU support.

**Features:**
- Installs Docker if not present
- Pulls Ollama image (`ollama/ollama:0.12.0`)
- Configures GPU access via `--gpus all`
- Pulls `gpt-oss:120b` model
- Exposes OpenAI-compatible API endpoint

**Environment Variables:**
- `MODEL_NAME` - Model to pull (default: `gpt-oss:120b`)
- `OLLAMA_IMAGE` - Ollama Docker image (default: `ollama/ollama:0.12.0`)
- `DATA_DIR` - Data directory (default: `/opt/ollama`)
- `PORT` - API port (default: `11434`)

**Target:** NVIDIA GPUs with CUDA support

## Prerequisites

### Local Machine
- Bash shell
- `curl` - For API requests
- `jq` - For JSON parsing
- `ssh` / `scp` - For remote access
- Terminal emulator (optional):
  - Linux/GNOME: `gnome-terminal` (auto-detected)
  - macOS: `Terminal.app` or `iTerm2` (manual command provided)
  - Windows: WSL or Git Bash (manual command provided)
  - If no terminal emulator is found, the script will display the manual command to run

### HotAisle Account
- HotAisle team name
- HotAisle API token
- SSH access configured (public key authentication)

### Remote VM Requirements
- Ubuntu/Debian-based Linux
- Internet connectivity
- Sudo access for `hotaisle` user
- GPU drivers (ROCm for AMD, CUDA for NVIDIA)

## Quick Start

1. **Set up environment variables:**
   ```bash
   export HOTAISLE_TEAM_NAME="your-team-name"
   export HOTAISLE_TOKEN="your-api-token"
   # Optional: if your HotAisle VMs use a different SSH username
   export REMOTE_USER="hotaisle"  # default
   ```

2. **Make scripts executable:**
   ```bash
   chmod +x deploy_and_run.sh destroy_vm.sh startup-amd.sh startup-nvidia.sh
   ```

3. **Deploy to a new VM:**
   ```bash
   ./deploy_and_run.sh
   ```

4. **When done, destroy the VM:**
   ```bash
   # VM name is stored in ~/.hotaisle_last_vm
   ./destroy_vm.sh $(cat ~/.hotaisle_last_vm)
   ```

## Workflow Example

```bash
# 1. Provision and deploy
./deploy_and_run.sh

# Output shows:
# - VM provisioning progress
# - SSH connection status
# - Remote setup progress (with spinner)
# - Ollama logs open in new terminal
# - Timing summary

# 2. Monitor logs
# - Check the separate terminal window
# - Or manually: ssh hotaisle@<IP> 'docker logs -f ollama'

# 3. Clean up
./destroy_vm.sh $(cat ~/.hotaisle_last_vm)
```

## VM Specifications

The default VM configuration when provisioning:
- **CPU:** 1x Intel Xeon Platinum 8470 (13 cores @ 2.0 GHz)
- **GPU:** 1x AMD MI300X
- **RAM:** 240 GB
- **Disk:** 12 TB
- **OS:** Ubuntu (via HotAisle default)

## Model Information

- **Model:** `gpt-oss:120b` (120 billion parameters)
- **API:** OpenAI-compatible endpoint at `http://<VM_IP>:11434/v1`
- **Context Length:** 4096 tokens
- **Features:** Streaming, system messages, temperature control

## File Locations

- **Last VM name:** `~/.hotaisle_last_vm` (created automatically)
- **SSH known_hosts:** `~/.ssh/known_hosts` (cleaned automatically)
- **Remote script path:** `/home/hotaisle/start.sh`
- **Ollama data:** `/opt/ollama` (on remote VM)

## Troubleshooting

### SSH Connection Issues
- Script automatically cleans old host keys
- Check that your SSH public key is configured in HotAisle
- Verify VM is reachable: `ping <VM_IP>`

### Model Pull Fails
- Check internet connectivity on remote VM
- Verify GPU is accessible: `docker logs ollama`
- Model download can take 30+ minutes for 120B model

### API Endpoint Not Accessible
- Verify Ollama is running: `ssh hotaisle@<IP> 'docker ps'`
- Check API endpoint: `curl http://<VM_IP>:11434/v1/models`
- Ensure firewall allows port 11434

### VM Provisioning Fails
- Verify `HOTAISLE_TEAM_NAME` and `HOTAISLE_TOKEN` are set
- Check API token permissions
- Review HotAisle API response for error details

## Notes

- The `gpt-oss:120b` model is large (~240GB) and takes significant time to download
- First-time model pull may take 30-60 minutes depending on network speed
- VM provisioning typically takes 1-3 minutes
- Scripts use `set -euo pipefail` for strict error handling
- All timing information is displayed at the end for performance analysis

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

