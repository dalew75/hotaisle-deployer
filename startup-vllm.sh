#!/usr/bin/env bash
# Setup for vLLM on an AMD GPU (ROCm) using the official Docker image.
# Target: MI300X / ROCm host. No Python/pip on host; uses vllm/vllm-openai-rocm.
#
# Usage:
#   VLLM_MODEL="Qwen/Qwen2.5-VL-72B-Instruct" ./startup-vllm.sh
#
# Launches vllm serve with: --port 8000 --tensor-parallel-size 1, configurable max-len and trust
#   (--trust-remote-code by default), and optional Qwen3 reasoning/tool flags.
#
# Context / VRAM: Very large --max-model-len increases KV cache use; on ~192GB VRAM, 200k+ context
#   leaves less room for model weights. Match each model’s spec (e.g. 32k, 128k, 200k) when possible.
#
# Gemma 4 / KeyError: 'embed_tokens.biases'
#   Some HF Gemma 4 weights include model.embed_tokens.biases; several vLLM releases only skip
#   extra weights ending in ".bias" (singular) and crash on ".biases". This is unrelated to
#   deploy flags. Workarounds: (1) docker pull the newest vllm/vllm-openai-rocm, or
#   (2) build Dockerfile.vllm-rocm-gemma4-hotfix and pass it via VLLM_IMAGE / --vllm-image.
#
# Optional environment overrides:
#   VLLM_MODEL     - Model(s) to serve, comma-separated; each gets its own container (default: Qwen/Qwen2.5-VL-72B-Instruct).
#   VLLM_PORT      - Starting host port (default: 8000); first instance PORT, second PORT+1, etc.
#   VLLM_IMAGE     - Docker image (default: vllm/vllm-openai-rocm:latest).
#                    There is no host pip install; this script runs docker pull on each run so :latest (or your tag) is refreshed.
#   HF_CACHE_DIR   - Host path for HuggingFace cache (default: /opt/vllm-hf-cache)
#   HF_TOKEN       - Optional HuggingFace token for gated models
#   VLLM_TRUST_REMOTE_CODE  - If 1/true/yes, pass --trust-remote-code (default: 1; often needed for newer archs e.g. Kimi).
#   VLLM_MAX_MODEL_LEN     - --max-model-len value (default: 131072 = 128k; raise for spec e.g. 200k+ or use --vllm-extra-args).
#   VLLM_USE_QWEN3_TOOL_STACK - If 1/true/yes, add Qwen3 reasoning+tool args (default: 1; set 0 for non-Qwen models).
#   VLLM_DISABLE_REASONING - If 1/true/yes, disable thinking/reasoning-style serving: adds
#       --default-chat-template-kwargs '{"enable_thinking": false}' (Gemma, Qwen3, etc.; vLLM dropped --enable-reasoning),
#       and omits the preset --reasoning-parser when the Qwen3 tool stack is still enabled (tools without reasoning parser).
#   TAILNET_ONLY   - 1 = publish ports on the Tailscale IP only (see secure-net.sh)
#   VLLM_EXTRA_ARGS - Extra flags passed through after the above (e.g. --quantization awq; duplicate flags may be last-wins).
#
# See: https://docs.vllm.ai/en/stable/getting_started/installation/gpu.html?device=rocm

set -euo pipefail

# Returns 0 if value looks enabled (1, true, yes, on, y)
_vllm_truthy() {
  case "${1:-}" in
    1|y|Y|true|True|yes|Yes|on|ON) return 0 ;;
  esac
  return 1
}

VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-VL-72B-Instruct}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai-rocm:latest}"
HF_CACHE_DIR="${HF_CACHE_DIR:-/opt/vllm-hf-cache}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"
VLLM_TRUST_REMOTE_CODE="${VLLM_TRUST_REMOTE_CODE:-1}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-131072}"
VLLM_USE_QWEN3_TOOL_STACK="${VLLM_USE_QWEN3_TOOL_STACK:-1}"
VLLM_DISABLE_REASONING="${VLLM_DISABLE_REASONING:-0}"

if [[ ! "$VLLM_MAX_MODEL_LEN" =~ ^[0-9]+$ ]] || [[ "$VLLM_MAX_MODEL_LEN" -lt 1 ]]; then
  echo "[!] VLLM_MAX_MODEL_LEN must be a positive integer, got: $VLLM_MAX_MODEL_LEN"
  exit 1
fi

if _vllm_truthy "$VLLM_TRUST_REMOTE_CODE"; then
  VLLM_TRUST_FLAGS=(--trust-remote-code)
else
  VLLM_TRUST_FLAGS=()
fi
if _vllm_truthy "$VLLM_USE_QWEN3_TOOL_STACK"; then
  if _vllm_truthy "$VLLM_DISABLE_REASONING"; then
    VLLM_QWEN_FLAGS=(--enable-auto-tool-choice --tool-call-parser qwen3_coder)
  else
    VLLM_QWEN_FLAGS=(--reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder)
  fi
else
  VLLM_QWEN_FLAGS=()
fi
if _vllm_truthy "$VLLM_DISABLE_REASONING"; then
  VLLM_REASONING_OFF_FLAGS=(--default-chat-template-kwargs '{"enable_thinking": false}')
else
  VLLM_REASONING_OFF_FLAGS=()
fi

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
echo "[*] max-model-len:  $VLLM_MAX_MODEL_LEN"
if _vllm_truthy "$VLLM_TRUST_REMOTE_CODE"; then
  echo "[*] trust-remote-code: yes"
else
  echo "[*] trust-remote-code: no"
fi
if _vllm_truthy "$VLLM_USE_QWEN3_TOOL_STACK"; then
  if _vllm_truthy "$VLLM_DISABLE_REASONING"; then
    echo "[*] Qwen3 tool stack:   yes (tools only; reasoning-parser omitted — disable reasoning)"
  else
    echo "[*] Qwen3 tool stack:   yes (reasoning-parser, tool-call-parser)"
  fi
else
  echo "[*] Qwen3 tool stack:   no"
fi
if _vllm_truthy "$VLLM_DISABLE_REASONING"; then
  echo "[*] reasoning / thinking: off (enable_thinking=false in chat template kwargs)"
else
  echo "[*] reasoning / thinking: default"
fi
[[ -n "$VLLM_EXTRA_ARGS" ]] && echo "[*] Extra vLLM args: $VLLM_EXTRA_ARGS"
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
    -p "${BIND_ADDR}:${port}:8000" \
    --ipc=host \
    "$VLLM_IMAGE" \
    "$model" \
    --port 8000 \
    --tensor-parallel-size 1 \
    --max-model-len "$VLLM_MAX_MODEL_LEN" \
    "${VLLM_TRUST_FLAGS[@]}" \
    "${VLLM_QWEN_FLAGS[@]}" \
    "${VLLM_REASONING_OFF_FLAGS[@]}" \
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
  echo "  http://${SHOW_HOST}:${port}/v1  (${VLLM_MODELS[i]})  logs: docker logs -f $name"
done
echo "==============================================="
