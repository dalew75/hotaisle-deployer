#!/usr/bin/env bash
# Setup for Ollama on an AMD GPU (ROCm) using the official Docker image.
# Target: MI300X / ROCm host. One server, one port; supports multiple models (comma-separated).
#
# Usage:
#   OLLAMA_MODEL="llama3.2:3b" ./startup-ollama.sh
#   OLLAMA_MODEL="llama3.2:3b,codellama:7b" ./startup-ollama.sh
#
# Optional environment overrides:
#   OLLAMA_MODEL  - Model(s) to pull and serve, comma-separated (default: gpt-oss:120b)
#   OLLAMA_PORT   - Host port for API (default: 8000); container listens on 11434
#   OLLAMA_IMAGE  - Docker image (default: ollama/ollama:rocm)
#   DATA_DIR      - Host path for Ollama data (default: /opt/ollama)
#   TAILNET_ONLY  - 1 = publish the port on the Tailscale IP only (see secure-net.sh)

set -euo pipefail

OLLAMA_MODEL="${OLLAMA_MODEL:-gpt-oss:120b}"
OLLAMA_PORT="${OLLAMA_PORT:-8000}"
OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:rocm}"
DATA_DIR="${DATA_DIR:-/opt/ollama}"

# Parse comma-separated models into array (trim whitespace per element)
IFS=',' read -ra OLLAMA_MODELS <<< "$OLLAMA_MODEL"
trimmed=()
for m in "${OLLAMA_MODELS[@]}"; do
  m=$(echo "$m" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -n "$m" ]] && trimmed+=("$m")
done
OLLAMA_MODELS=("${trimmed[@]}")
[[ ${#OLLAMA_MODELS[@]} -eq 0 ]] && OLLAMA_MODELS=("gpt-oss:120b")

echo "[*] Models:         ${OLLAMA_MODELS[*]}"
echo "[*] API port:       $OLLAMA_PORT"
echo "[*] Docker image:   $OLLAMA_IMAGE"
echo "[*] Data dir:       $DATA_DIR"
echo

# ---- Basic ROCm sanity hint (non-fatal) ------------------------------------
if [[ ! -e /dev/kfd ]]; then
  echo "[!] /dev/kfd not found. ROCm may not be set up correctly or GPU not exposed to this VM."
  echo "    The container may fail to use the GPU until ROCm / drivers are configured."
  echo
fi

# ---- Where to publish the API port -------------------------------------------
# TAILNET_ONLY=1 (set by deploy_and_run.sh after secure-net.sh): bind to the Tailscale IP only,
# so the API is never on the public interface. Docker-published ports bypass ufw, so this matters.
if [[ "${TAILNET_ONLY:-0}" == "1" ]]; then
  BIND_ADDR="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  if [[ -z "$BIND_ADDR" ]]; then
    echo "[!] ERROR: TAILNET_ONLY=1 but no tailnet IP (did secure-net.sh run?). Refusing to expose the API."
    exit 1
  fi
  SHOW_HOST="${TS_HOSTNAME:-$BIND_ADDR}"  # MagicDNS name, or the 100.x IP
else
  BIND_ADDR="0.0.0.0"
  SHOW_HOST="$(hostname -I | awk '{print $1}')"
  echo "[!] WARNING: publishing the API on ALL interfaces (public, no auth)."
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
sudo chown "$USER":"$USER" "$DATA_DIR" 2>/dev/null || true

# ---- Pull Ollama ROCm image --------------------------------------------------
echo "[*] Pulling Ollama image: $OLLAMA_IMAGE ..."
sudo docker pull "$OLLAMA_IMAGE"

# ---- Stop/remove existing container ---------------------------------------
if sudo docker ps -a --format '{{.Names}}' | grep -q '^ollama$'; then
  echo "[*] Removing existing 'ollama' container..."
  sudo docker rm -f ollama
fi

# ---- Run Ollama container (ROCm / AMD) ---------------------------------------
echo "[*] Starting Ollama container on port $OLLAMA_PORT ..."
sudo docker run -d \
  --name ollama \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add video \
  --ipc=host \
  -p "${BIND_ADDR}:${OLLAMA_PORT}:11434" \
  -v "${DATA_DIR}:/root/.ollama" \
  "$OLLAMA_IMAGE"

echo "[*] Waiting for Ollama to start..."
sleep 10

# ---- Pull each model inside the container ------------------------------------
for model in "${OLLAMA_MODELS[@]}"; do
  echo "[*] Pulling model: $model ..."
  sudo docker exec ollama ollama pull "$model"
done

echo
echo "==============================================="
echo "[✔] Ollama setup complete."
echo
echo "Ollama (OpenAI-compatible) endpoint:"
echo "  http://${SHOW_HOST}:${OLLAMA_PORT}/v1"
echo "  Models: ${OLLAMA_MODELS[*]}"
echo
echo "Logs:"
echo "  docker logs -f ollama"
echo "==============================================="
