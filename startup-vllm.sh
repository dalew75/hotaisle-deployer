#!/usr/bin/env bash
# Setup for vLLM on an AMD GPU (ROCm) using the official Docker image.
# Target: MI300X / ROCm host. No Python/pip on host; uses vllm/vllm-openai-rocm.
#
# Usage:
#   VLLM_MODEL="Qwen/Qwen2.5-VL-72B-Instruct" ./startup-vllm.sh
#
# Optional environment overrides:
#   VLLM_MODEL   - Model to serve (default: Qwen/Qwen2.5-VL-72B-Instruct)
#                  If comma-separated list, the first model is served (vLLM serves one per process).
#   VLLM_PORT    - Port for vLLM API (default: 8000)
#   VLLM_IMAGE   - Docker image (default: vllm/vllm-openai-rocm:latest)
#   HF_CACHE_DIR - Host path for HuggingFace cache (default: /opt/vllm-hf-cache)
#   HF_TOKEN     - Optional HuggingFace token for gated models
#
# See: https://docs.vllm.ai/en/stable/getting_started/installation/gpu.html?device=rocm

set -euo pipefail

VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-VL-72B-Instruct}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai-rocm:latest}"
HF_CACHE_DIR="${HF_CACHE_DIR:-/opt/vllm-hf-cache}"

# If comma-separated list, use first model for vllm serve
MODEL_TO_SERVE="${VLLM_MODEL%%,*}"

echo "[*] Model:          $MODEL_TO_SERVE"
echo "[*] API port:       $VLLM_PORT"
echo "[*] Docker image:   $VLLM_IMAGE"
echo "[*] HF cache:       $HF_CACHE_DIR"
echo

# ---- Basic ROCm sanity hint (non-fatal) ------------------------------------
if [[ ! -e /dev/kfd ]]; then
  echo "[!] /dev/kfd not found. ROCm may not be set up correctly or GPU not exposed to this VM."
  echo "    The container may fail to use the GPU until ROCm / drivers are configured."
  echo
fi

# ---- Install Docker if needed ----------------------------------------------
if ! command -v docker &>/dev/null; then
  echo "[*] Docker not found. Installing docker.io..."
  sudo apt-get update -y
  sudo apt-get install -y docker.io docker-compose-plugin
  sudo systemctl enable docker
  sudo systemctl start docker
fi

# ---- Prepare HuggingFace cache dir -----------------------------------------
echo "[*] Preparing HuggingFace cache at $HF_CACHE_DIR..."
sudo mkdir -p "$HF_CACHE_DIR"
sudo chown "$USER":"$USER" "$HF_CACHE_DIR" 2>/dev/null || true

# ---- Pull vLLM ROCm image --------------------------------------------------
echo "[*] Pulling vLLM ROCm image: $VLLM_IMAGE ..."
sudo docker pull "$VLLM_IMAGE"

# ---- Stop/remove existing container ---------------------------------------
if sudo docker ps -a --format '{{.Names}}' | grep -q '^vllm$'; then
  echo "[*] Removing existing 'vllm' container..."
  sudo docker rm -f vllm
fi

# ---- Run vLLM container (ROCm / AMD) ---------------------------------------
# Flags per official vLLM ROCm Docker docs
echo "[*] Starting vLLM container: $MODEL_TO_SERVE on port $VLLM_PORT ..."
sudo docker run -d \
  --name vllm \
  --group-add=video \
  --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined \
  --device /dev/kfd \
  --device /dev/dri \
  -v "${HF_CACHE_DIR}:/root/.cache/huggingface" \
  ${HF_TOKEN:+--env "HF_TOKEN=$HF_TOKEN"} \
  -p "${VLLM_PORT}:8000" \
  --ipc=host \
  "$VLLM_IMAGE" \
  --model "$MODEL_TO_SERVE"

echo "[*] Waiting for vLLM to start..."
sleep 10

echo
echo "==============================================="
echo "[✔] vLLM setup complete."
echo
echo "vLLM server (OpenAI-compatible) endpoint:"
echo "  http://$(hostname -I | awk '{print $1}'):${VLLM_PORT}/v1"
echo "  Model: ${MODEL_TO_SERVE}"
echo
echo "Logs:"
echo "  docker logs -f vllm"
echo "==============================================="
