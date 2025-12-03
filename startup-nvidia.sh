#!/usr/bin/env bash
# Minimal setup for Ollama + gpt-oss:120b with an OpenAI-style API.
# Usage:
#   chmod +x minimal-ollama-gpt-oss.sh
#   ./minimal-ollama-gpt-oss.sh
#
# Optional env vars:
#   MODEL_NAME=gpt-oss:20b  DATA_DIR=/my/ollama  PORT=11434  OLLAMA_IMAGE=ollama/ollama:latest

set -euo pipefail

MODEL_NAME="${MODEL_NAME:-gpt-oss:120b}"
OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:0.12.0}"
DATA_DIR="${DATA_DIR:-/opt/ollama}"
PORT="${PORT:-11434}"

echo "[*] Model:        $MODEL_NAME"
echo "[*] Ollama image: $OLLAMA_IMAGE"
echo "[*] Data dir:     $DATA_DIR"
echo "[*] API port:     $PORT"

# ---- Sanity checks ---------------------------------------------------------

if ! command -v nvidia-smi &>/dev/null; then
  echo "[!] nvidia-smi not found. Make sure GPU drivers are installed and accessible." >&2
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

# ---- Pull Ollama image -----------------------------------------------------

echo "[*] Pulling Ollama image: $OLLAMA_IMAGE ..."
sudo docker pull "$OLLAMA_IMAGE"

# ---- Stop/remove existing container ---------------------------------------

if sudo docker ps -a --format '{{.Names}}' | grep -q '^ollama$'; then
  echo "[*] Removing existing 'ollama' container..."
  sudo docker rm -f ollama
fi

# ---- Run Ollama container --------------------------------------------------

echo "[*] Starting Ollama container on port $PORT..."
sudo docker run -d \
  --name ollama \
  --gpus all \
  -p "${PORT}:11434" \
  -v "${DATA_DIR}:/root/.ollama" \
  "$OLLAMA_IMAGE"

echo "[*] Waiting for Ollama to start..."
sleep 10

# ---- Pull gpt-oss model inside the container -------------------------------

echo "[*] Pulling model inside container: $MODEL_NAME ..."
sudo docker exec ollama ollama pull "$MODEL_NAME"

echo
echo "==============================================="
echo "[✔] Setup complete."
echo
echo "Ollama API base URL (native):"
echo "  http://$(hostname -I | awk '{print $1}'):${PORT}"
echo
echo "OpenAI-compatible endpoint (for TypingMind / SDKs):"
echo "  http://$(hostname -I | awk '{print $1}'):${PORT}/v1"
echo "  Model name: ${MODEL_NAME}"
echo "  API key: any non-empty string (ignored by Ollama)"
echo "==============================================="
