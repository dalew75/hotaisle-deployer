#!/usr/bin/env bash
# Minimal setup for Ollama + gpt-oss:120b with an OpenAI-style API on an AMD GPU (ROCm).
# Target: MI300X / ROCm host with Docker already installed or installable via apt.
#
# Usage:
#   chmod +x minimal-ollama-gpt-oss.sh
#   ./minimal-ollama-gpt-oss.sh
#
# Optional environment overrides:
#   MODEL_NAME=gpt-oss:20b \
#   OLLAMA_IMAGE=ollama/ollama:rocm \
#   DATA_DIR=/my/ollama \
#   PORT=11434 \
#   ./minimal-ollama-gpt-oss.sh

set -euo pipefail

MODEL_NAME="${MODEL_NAME:-gpt-oss:120b}"
OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:rocm}"
DATA_DIR="${DATA_DIR:-/opt/ollama}"
PORT="${PORT:-11434}"

echo "[*] Model:        $MODEL_NAME"
echo "[*] Ollama image: $OLLAMA_IMAGE"
echo "[*] Data dir:     $DATA_DIR"
echo "[*] API port:     $PORT"
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

# ---- Prepare data dir ------------------------------------------------------

echo "[*] Preparing data directory at $DATA_DIR..."
sudo mkdir -p "$DATA_DIR"
sudo chown "$USER":"$USER" "$DATA_DIR"

# ---- Pull Ollama ROCm image ------------------------------------------------

echo "[*] Pulling Ollama image: $OLLAMA_IMAGE ..."
sudo docker pull "$OLLAMA_IMAGE"

# ---- Stop/remove existing container ---------------------------------------

if sudo docker ps -a --format '{{.Names}}' | grep -q '^ollama$'; then
  echo "[*] Removing existing 'ollama' container..."
  sudo docker rm -f ollama
fi

# ---- Run Ollama container (ROCm / AMD) ------------------------------------

echo "[*] Starting Ollama container on port $PORT (ROCm / AMD)..."
sudo docker run -d \
  --name ollama \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add video \
  --ipc=host \
  -p "${PORT}:11434" \
  -v "${DATA_DIR}:/root/.ollama" \
  "$OLLAMA_IMAGE"

echo "[*] Waiting for Ollama to start..."
sleep 10

# ---- Pull model inside the container --------------------------------------

echo "[*] Pulling model inside container: $MODEL_NAME ..."
sudo docker exec ollama ollama pull "$MODEL_NAME"

echo
echo "==============================================="
echo "[✔] Setup complete."
echo
echo "Ollama native API base URL:"
echo "  http://$(hostname -I | awk '{print $1}'):${PORT}"
echo
echo "OpenAI-compatible endpoint (for TypingMind / SDKs):"
echo "  http://$(hostname -I | awk '{print $1}'):${PORT}/v1"
echo "  Model name: ${MODEL_NAME}"
echo "  API key: any non-empty string (ignored by Ollama)"
echo
echo "Check logs with:"
echo "  docker logs -f ollama"
echo "==============================================="
