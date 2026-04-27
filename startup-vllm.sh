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
#   VLLM_MODEL     - Model(s) to serve, comma-separated; each gets its own container (default: Qwen/Qwen2.5-VL-72B-Instruct).
#   VLLM_PORT      - Starting host port (default: 8000); first instance PORT, second PORT+1, etc.
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

# Parse comma-separated models into array (trim whitespace per element)
IFS=',' read -ra VLLM_MODELS <<< "$VLLM_MODEL"
trimmed=()
for m in "${VLLM_MODELS[@]}"; do
  m=$(echo "$m" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -n "$m" ]] && trimmed+=("$m")
done
VLLM_MODELS=("${trimmed[@]}")
[[ ${#VLLM_MODELS[@]} -eq 0 ]] && VLLM_MODELS=("Qwen/Qwen2.5-VL-72B-Instruct")

echo "[*] Models:         ${VLLM_MODELS[*]}"
echo "[*] Starting port:  $VLLM_PORT"
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

# ---- Run one vLLM container per model (DRY loop) ----------------------------
# Image entrypoint is "vllm serve"; pass model as positional, then flags.
# Single model -> container name "vllm"; multiple -> "vllm-8000", "vllm-8001", ...
HOST_IP=$(hostname -I | awk '{print $1}')
for i in "${!VLLM_MODELS[@]}"; do
  model="${VLLM_MODELS[i]}"
  port=$((VLLM_PORT + i))
  if [[ ${#VLLM_MODELS[@]} -eq 1 ]]; then
    name="vllm"
  else
    name="vllm-${port}"
  fi
  if sudo docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
    echo "[*] Removing existing '$name' container..."
    sudo docker rm -f "$name"
  fi
  echo "[*] Starting vLLM container: $model on port $port (name: $name) ..."
  sudo docker run -d \
    --name "$name" \
    --group-add=video \
    --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    --device /dev/kfd \
    --device /dev/dri \
    -v "${HF_CACHE_DIR}:/root/.cache/huggingface" \
    ${HF_TOKEN:+--env "HF_TOKEN=$HF_TOKEN"} \
    ${HF_TOKEN:+--env "HUGGING_FACE_HUB_TOKEN=$HF_TOKEN"} \
    -p "${port}:8000" \
    --ipc=host \
    "$VLLM_IMAGE" \
    "$model" \
    --port 8000 \
    --tensor-parallel-size 1 \
    --max-model-len 262144 \
    --reasoning-parser qwen3 \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder \
    $VLLM_EXTRA_ARGS
done

echo "[*] Waiting for vLLM to start..."
sleep 10

echo
echo "==============================================="
echo "[✔] vLLM setup complete."
echo
echo "vLLM server(s) (OpenAI-compatible) endpoint(s):"
for i in "${!VLLM_MODELS[@]}"; do
  port=$((VLLM_PORT + i))
  if [[ ${#VLLM_MODELS[@]} -eq 1 ]]; then
    name="vllm"
  else
    name="vllm-${port}"
  fi
  echo "  http://${HOST_IP}:${port}/v1  (${VLLM_MODELS[i]})  logs: docker logs -f $name"
done
echo "==============================================="
