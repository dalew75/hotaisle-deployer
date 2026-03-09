#!/usr/bin/env bash
# Setup for vLLM on an AMD GPU (ROCm). Installs Python/pip, vLLM, and runs vLLM server.
# Target: MI300X / ROCm host.
#
# Usage:
#   VLLM_MODEL="Qwen/Qwen2.5-VL-72B-Instruct" ./startup-vllm.sh
#
# Optional environment overrides:
#   VLLM_MODEL   - Model to serve (default: Qwen/Qwen2.5-VL-72B-Instruct)
#                  If comma-separated list, the first model is served (vLLM serves one per process).
#   VLLM_PORT    - Port for vLLM API (default: 8000)
#   VLLM_LOG     - Log file path (default: /tmp/vllm.log)
#   VLLM_ROCM_INDEX - Pip index for ROCm wheels (default: https://wheels.vllm.ai/rocm/)
#                     Pre-built wheels require ROCm 7.0; for older ROCm, build from source.

set -euo pipefail

VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-VL-72B-Instruct}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_LOG="${VLLM_LOG:-/tmp/vllm.log}"

# If comma-separated list, use first model for vllm serve
MODEL_TO_SERVE="${VLLM_MODEL%%,*}"

echo "[*] Model to serve: $MODEL_TO_SERVE"
echo "[*] API port:       $VLLM_PORT"
echo "[*] Log file:       $VLLM_LOG"
echo

# ---- Basic ROCm sanity hint (non-fatal) ------------------------------------
if [[ ! -e /dev/kfd ]]; then
  echo "[!] /dev/kfd not found. ROCm may not be set up correctly or GPU not exposed to this VM."
  echo "    vLLM may fail to use the GPU until ROCm / drivers are configured."
  echo
fi

# ---- Install Python/pip if needed ------------------------------------------
if ! command -v python3 &>/dev/null; then
  echo "[*] Python3 not found. Installing python3, python3-pip, python3-venv..."
  sudo apt-get update -y
  sudo apt-get install -y python3 python3-pip python3-venv python3-dev
fi

if ! command -v pip3 &>/dev/null && ! python3 -m pip --version &>/dev/null 2>&1; then
  echo "[*] pip not found. Installing python3-pip..."
  sudo apt-get update -y
  sudo apt-get install -y python3-pip
fi

# Prefer pip3 or python3 -m pip
PIP_CMD=""
if command -v pip3 &>/dev/null; then
  PIP_CMD="pip3"
elif python3 -m pip --version &>/dev/null 2>&1; then
  PIP_CMD="python3 -m pip"
else
  echo "[!] ERROR: Could not find pip. Install python3-pip."
  exit 1
fi

echo "[*] Using: $PIP_CMD ($($PIP_CMD --version 2>/dev/null || true))"

# ---- Install vLLM (ROCm build for AMD GPUs) ----------------------------------
# Default pip install vllm gives CUDA build; AMD/ROCm needs wheels from vLLM's ROCm index.
# See: https://docs.vllm.ai/en/stable/getting_started/installation/gpu.html?device=rocm
VLLM_ROCM_INDEX="${VLLM_ROCM_INDEX:-https://wheels.vllm.ai/rocm/}"
if $PIP_CMD show vllm &>/dev/null; then
  echo "[*] Uninstalling existing vllm (may be CUDA build)..."
  $PIP_CMD uninstall -y vllm 2>/dev/null || true
fi
echo "[*] Installing vllm for ROCm/AMD from $VLLM_ROCM_INDEX (this may take a few minutes)..."
$PIP_CMD install vllm --no-cache-dir \
  --index-url "$VLLM_ROCM_INDEX" \
  --extra-index-url https://pypi.org/simple

# ---- Run vLLM server in background ------------------------------------------
echo "[*] Starting vLLM server: $MODEL_TO_SERVE on port $VLLM_PORT ..."
nohup vllm serve "$MODEL_TO_SERVE" --port "$VLLM_PORT" \
  > "$VLLM_LOG" 2>&1 &
VLLM_PID=$!
echo $VLLM_PID | sudo tee /var/run/vllm.pid >/dev/null 2>&1 || true

echo "[*] Waiting for vLLM to start..."
sleep 5

echo
echo "==============================================="
echo "[✔] vLLM setup complete."
echo
echo "vLLM server (OpenAI-compatible) endpoint:"
echo "  http://$(hostname -I | awk '{print $1}'):${VLLM_PORT}/v1"
echo "  Model: ${MODEL_TO_SERVE}"
echo
echo "Logs:"
echo "  tail -f $VLLM_LOG"
echo "==============================================="
