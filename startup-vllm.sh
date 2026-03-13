#!/usr/bin/env bash
# Setup for vLLM on an AMD GPU (ROCm) using the official Docker image.
# Target: MI300X / ROCm host. No Python/pip on host; uses vllm/vllm-openai-rocm.
#
# Usage:
#   VLLM_MODEL="Qwen/Qwen2.5-VL-72B-Instruct" ./startup-vllm.sh
#
# Launches via: vllm serve <model> --port 8000 --tensor-parallel-size 1 --max-model-len 262144
#               --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder
#
# Optional environment overrides:
#   VLLM_MODEL     - Model to serve (default: Qwen/Qwen2.5-VL-72B-Instruct). Passed as positional arg.
#   VLLM_PORT      - Host port for API (default: 8000); container always listens on 8000.
#   VLLM_IMAGE     - Docker image (default: vllm/vllm-openai-rocm:latest)
#   HF_CACHE_DIR   - Host path for HuggingFace cache (default: /opt/vllm-hf-cache)
#   HF_TOKEN       - Optional HuggingFace token for gated models
#   VLLM_EXTRA_ARGS - Extra flags appended after the fixed flags (e.g. --quantization awq)
#
# See: https://docs.vllm.ai/en/stable/getting_started/installation/gpu.html?device=rocm

set -euo pipefail

VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-VL-72B-Instruct}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai-rocm:latest}"
HF_CACHE_DIR="${HF_CACHE_DIR:-/opt/vllm-hf-cache}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"

# If comma-separated list, use first model for vllm serve
MODEL_TO_SERVE="${VLLM_MODEL%%,*}"

echo "[*] Model:          $MODEL_TO_SERVE"
echo "[*] API port:       $VLLM_PORT"
echo "[*] Docker image:   $VLLM_IMAGE"
echo "[*] HF cache:       $HF_CACHE_DIR"
[[ -n "$VLLM_EXTRA_ARGS" ]] && echo "[*] Extra vLLM args: $VLLM_EXTRA_ARGS"
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
# Image entrypoint is "vllm serve"; pass model as positional, then flags.
# Container listens on 8000; host port is VLLM_PORT via -p mapping.
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
  ${HF_TOKEN:+--env "HUGGING_FACE_HUB_TOKEN=$HF_TOKEN"} \
  -p "${VLLM_PORT}:8000" \
  --ipc=host \
  "$VLLM_IMAGE" \
  "$MODEL_TO_SERVE" \
  --port 8000 \
  --tensor-parallel-size 1 \
  --max-model-len 262144 \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  $VLLM_EXTRA_ARGS

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
