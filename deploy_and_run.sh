#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  deploy_and_run.sh
#
#  1. Optionally provisions a new HotAisle VM (if no IP provided)
#  2. Extracts SSH IP from the HotAisle response
#  3. Stores last VM name in ~/.hotaisle_last_vm
#  4. Cleans host keys for that IP
#  5. Uploads startup script (Ollama or vLLM) to the VM
#  6. Runs it remotely via sudo (with a progress spinner)
#  7. Opens a new terminal window for logs (docker logs -f ollama or vllm)
#  8. Prints timing stats at the end
#
#  Usage: ./deploy_and_run.sh --backend <ollama|vllm> [options] [GPU_IP]
#  --backend (required): ollama or vllm. No default.
#  --model: comma-separated. Ollama: multiple models on one port. vLLM: one container per model, ports PORT, PORT+1, ...
#  --port: starting port (default 8000). Ollama uses single port; vLLM uses PORT, PORT+1, ...
#  vLLM-only: --vllm-max-model-len <n>  (default 131072 on server), --vllm-trust-remote-code, --no-vllm-trust-remote-code,
#             --vllm-no-qwen-tool-stack, --vllm-disable-reasoning, [--vllm-image <docker-ref>], [--hf-token], [--vllm-extra-args]
#
#  --vllm-disable-reasoning: turns off “thinking”/reasoning-style serving for Gemma, Qwen3, etc. vLLM removed --enable-reasoning;
#             this sets --default-chat-template-kwargs '{"enable_thinking": false}' and skips the preset --reasoning-parser when
#             the Qwen3 tool stack is on. Override template kwargs via --vllm-extra-args if needed (passed last).
#
#  vLLM version: served from Docker (startup-vllm.sh), not host pip. Default image is vllm/vllm-openai-rocm:latest;
#  each remote run does docker pull first, so :latest tracks new publishes. Pin with --vllm-image org/img:tag for reproducibility.
#  Gemma 4 + KeyError embed_tokens.biases: see Dockerfile.vllm-rocm-gemma4-hotfix in this repo.
#  Example: ./deploy_and_run.sh --backend ollama --model llama3.2:3b
#           ./deploy_and_run.sh --backend ollama --model "llama3.2:3b,codellama:7b" --port 8000
#           ./deploy_and_run.sh --backend vllm --model Qwen/Qwen2.5-72B-Instruct
#           ./deploy_and_run.sh --backend vllm --model "A,B" --port 9000
#           ./deploy_and_run.sh --backend vllm --model org/model --vllm-no-qwen-tool-stack --vllm-max-model-len 32768
#           ./deploy_and_run.sh --backend vllm --model google/gemma-4-12b-it --vllm-disable-reasoning --vllm-no-qwen-tool-stack
###############################################################################

REMOTE_USER="${REMOTE_USER:-hotaisle}"
REMOTE_PATH="/home/${REMOTE_USER}/start.sh"
KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"
LAST_VM_FILE="${HOME}/.hotaisle_last_vm"

# Parse arguments: --backend, --model, --port, vLLM options, then optional GPU_IP
BACKEND=""
MODEL_ARG=""
PORT_ARG="8000"
HF_TOKEN_ARG=""
VLLM_EXTRA_ARGS_ARG=""
# vLLM-only (applied when --backend vllm); ignored for ollama
VLLM_MAX_LEN_CLI=""
VLLM_TRUST_CLI="" # empty = server defaults; 0/1 = explicit
VLLM_NO_QWEN=false
VLLM_DISABLE_REASONING_FLAG=false
VLLM_IMAGE_ARG=""
while [[ $# -gt 0 ]] && [[ "$1" == -* ]]; do
  case "$1" in
    --backend)
      BACKEND="$2"
      shift 2
      ;;
    --model)
      MODEL_ARG="$2"
      shift 2
      ;;
    --port)
      PORT_ARG="$2"
      shift 2
      ;;
    --hf-token)
      HF_TOKEN_ARG="$2"
      shift 2
      ;;
    --vllm-extra-args)
      VLLM_EXTRA_ARGS_ARG="$2"
      shift 2
      ;;
    --vllm-max-model-len)
      VLLM_MAX_LEN_CLI="$2"
      shift 2
      ;;
    --vllm-trust-remote-code)
      VLLM_TRUST_CLI=1
      shift
      ;;
    --no-vllm-trust-remote-code)
      VLLM_TRUST_CLI=0
      shift
      ;;
    --vllm-no-qwen-tool-stack)
      VLLM_NO_QWEN=true
      shift
      ;;
    --vllm-disable-reasoning)
      VLLM_DISABLE_REASONING_FLAG=true
      shift
      ;;
    --vllm-image)
      VLLM_IMAGE_ARG="$2"
      shift 2
      ;;
    *)
      echo "[!] Unknown option: $1"
      exit 1
      ;;
  esac
done
GPU_IP="${1:-}"

# Require --backend ollama or vllm
if [[ "$BACKEND" != "ollama" && "$BACKEND" != "vllm" ]]; then
  echo "[!] ERROR: Must specify --backend ollama or --backend vllm."
  exit 1
fi

# Validate --port is a positive integer
if [[ -n "$PORT_ARG" && ! "$PORT_ARG" =~ ^[0-9]+$ ]] || [[ -n "$PORT_ARG" && "$PORT_ARG" -lt 1 ]]; then
  echo "[!] ERROR: --port must be a positive integer."
  exit 1
fi

# Validate --vllm-max-model-len when set
if [[ -n "$VLLM_MAX_LEN_CLI" ]]; then
  if [[ ! "$VLLM_MAX_LEN_CLI" =~ ^[0-9]+$ ]] || [[ "$VLLM_MAX_LEN_CLI" -lt 1 ]]; then
    echo "[!] ERROR: --vllm-max-model-len must be a positive integer."
    exit 1
  fi
fi

# Set script and model/port by backend
if [[ "$BACKEND" == "vllm" ]]; then
  LOCAL_SCRIPT="startup-vllm.sh"
  VLLM_MODEL="${MODEL_ARG:-Qwen/Qwen2.5-VL-72B-Instruct}"
  VLLM_PORT="$PORT_ARG"
  OLLAMA_MODEL=""
  # vLLM: validate each comma-separated segment is a Hugging Face ID (no Ollama-style tag)
  if [[ -n "$MODEL_ARG" ]]; then
    IFS=',' read -ra SEGMENTS <<< "$MODEL_ARG"
    for seg in "${SEGMENTS[@]}"; do
      seg=$(echo "$seg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -z "$seg" ]] && continue
      if [[ "$seg" == *:* && "$seg" != */* ]]; then
        echo "[!] ERROR: With --backend vllm, --model must be Hugging Face model ID(s) (e.g. Qwen/Qwen2.5-72B-Instruct), not an Ollama tag."
        echo "    Invalid segment: $seg"
        exit 1
      fi
    done
  fi
else
  LOCAL_SCRIPT="startup-ollama.sh"
  OLLAMA_MODEL="${MODEL_ARG:-gpt-oss:120b}"
  OLLAMA_PORT="$PORT_ARG"
  VLLM_MODEL=""
  VLLM_PORT=""
fi

# Timing helpers
script_start_ts=$(date +%s)
provision_secs=0
ssh_wait_secs=0
scp_secs=0
startup_secs=0

echo "------------------------------------------------------"
echo "[*] Backend:         $BACKEND"
echo "[*] Local script:    $LOCAL_SCRIPT"
echo "[*] Provided GPU IP: ${GPU_IP:-<none>}"
if [[ "$BACKEND" == "vllm" ]]; then
  echo "[*] vLLM model(s):    $VLLM_MODEL"
  echo "[*] Starting port:    $VLLM_PORT"
  if [[ -n "$VLLM_MAX_LEN_CLI" ]]; then
    echo "[*] vLLM max-model-len: $VLLM_MAX_LEN_CLI"
  else
    echo "[*] vLLM max-model-len: (server default 131072)"
  fi
  if [[ -n "$VLLM_TRUST_CLI" ]]; then
    echo "[*] trust-remote-code:  $VLLM_TRUST_CLI"
  else
    echo "[*] trust-remote-code:  (server default 1)"
  fi
  if [[ "$VLLM_NO_QWEN" == true ]]; then
    echo "[*] Qwen3 tool stack:   off"
  else
    echo "[*] Qwen3 tool stack:   (server default on)"
  fi
  if [[ "$VLLM_DISABLE_REASONING_FLAG" == true ]]; then
    echo "[*] vLLM reasoning:     disabled (see startup-vllm.sh)"
  else
    echo "[*] vLLM reasoning:     default"
  fi
  if [[ -n "$HF_TOKEN_ARG" ]]; then
    echo "[*] HF token:         (set)"
  fi
  if [[ -n "$VLLM_EXTRA_ARGS_ARG" ]]; then
    echo "[*] vLLM extra args:  $VLLM_EXTRA_ARGS_ARG"
  fi
  if [[ -n "$VLLM_IMAGE_ARG" ]]; then
    echo "[*] vLLM Docker image: $VLLM_IMAGE_ARG"
  else
    echo "[*] vLLM Docker image: (server default vllm/vllm-openai-rocm:latest, pulled each deploy)"
  fi
else
  echo "[*] Ollama model(s):  $OLLAMA_MODEL"
  echo "[*] Port:             $OLLAMA_PORT"
fi
echo "------------------------------------------------------"

###############################################################################
#  Ensure startup script exists locally
###############################################################################
if [[ ! -f "$LOCAL_SCRIPT" ]]; then
  echo "[!] ERROR: Local script '$LOCAL_SCRIPT' not found."
  exit 1
fi

###############################################################################
#  If no IP provided → Provision new HotAisle VM
###############################################################################
if [[ -z "$GPU_IP" ]]; then
  echo "[*] No GPU IP provided — provisioning a new VM via HotAisle API..."

  # Must have these set
  : "${HOTAISLE_TEAM_NAME:?HOTAISLE_TEAM_NAME is not set}"
  : "${HOTAISLE_TOKEN:?HOTAISLE_TOKEN is not set}"

  HOTAISLE_USER_DATA_URL="${HOTAISLE_USER_DATA_URL:-}"

  # Build payload from known working VM specs
  PAYLOAD=$(cat <<JSON
{
  "cpu_cores": 13,
  "cpus": {
    "count": 1,
    "manufacturer": "Intel",
    "model": "Xeon Platinum 8470",
    "cores": 13,
    "frequency": 2000000000
  },
  "disk_capacity": 13194139533312,
  "gpus": [
    {
      "count": 1,
      "manufacturer": "AMD",
      "model": "MI300X"
    }
  ],
  "ram_capacity": 240518168576,
  "user_data_url": "${HOTAISLE_USER_DATA_URL}"
}
JSON
)

  prov_start_ts=$(date +%s)
  echo "[*] POSTing payload to HotAisle..."
  RESPONSE="$(
    curl -sS -X POST \
      "https://admin.hotaisle.app/api/teams/${HOTAISLE_TEAM_NAME}/virtual_machines/" \
      -H "accept: application/json" \
      -H "Authorization: Token ${HOTAISLE_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD"
  )"
  prov_end_ts=$(date +%s)
  provision_secs=$((prov_end_ts - prov_start_ts))

  echo "------------------------------------------------------"
  echo "[*] HotAisle provision response:"
  if command -v jq >/dev/null 2>&1; then
    echo "$RESPONSE" | jq .
  else
    echo "$RESPONSE"
  fi
  echo "------------------------------------------------------"

  # Store VM name locally for destroy_vm.sh
  VM_NAME="$(echo "$RESPONSE" | jq -r '.name')"
  echo "$VM_NAME" > "$LAST_VM_FILE"
  echo "[*] Recorded last provisioned VM name '$VM_NAME' in $LAST_VM_FILE"

  # Extract IP: prefer ssh_access.ip_address, fallback to ip_address
  if ! command -v jq >/dev/null 2>&1; then
    echo "[!] jq is required to parse HotAisle response."
    exit 1
  fi

  GPU_IP="$(echo "$RESPONSE" | jq -r '.ssh_access.ip_address // .ip_address')"

  if [[ -z "$GPU_IP" || "$GPU_IP" == "null" ]]; then
    echo "[!] ERROR: Could not extract a usable IP address from the HotAisle response."
    exit 1
  fi

  echo "[+] Provisioned GPU VM IP: $GPU_IP (provision step: ${provision_secs}s)"
else
  echo "[*] Using provided GPU IP (skipping provisioning): $GPU_IP"
fi

echo "------------------------------------------------------"
echo "[*] Deploying to GPU instance at: $GPU_IP"
echo "------------------------------------------------------"

###############################################################################
#  Clean old SSH host keys
###############################################################################
echo "[*] Cleaning old SSH host keys for ${GPU_IP}..."
if [[ -f "$KNOWN_HOSTS_FILE" ]]; then
  ssh-keygen -f "$KNOWN_HOSTS_FILE" -R "$GPU_IP" >/dev/null 2>&1 || true
  ssh-keygen -f "$KNOWN_HOSTS_FILE" -R "[$GPU_IP]" >/dev/null 2>&1 || true
fi

###############################################################################
#  SSH connection options
###############################################################################
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

###############################################################################
#  Wait for VM to be reachable
###############################################################################
echo "[*] Checking if $GPU_IP is reachable via SSH..."
ssh_wait_start_ts=$(date +%s)
until ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" "echo connected" &>/dev/null; do
  echo "[-] Not ready yet... retrying in 3 seconds."
  sleep 3
done
ssh_wait_end_ts=$(date +%s)
ssh_wait_secs=$((ssh_wait_end_ts - ssh_wait_start_ts))
echo "[+] Remote SSH is ready (waited ${ssh_wait_secs}s)."

###############################################################################
#  Upload startup script
###############################################################################
echo "[*] Copying $LOCAL_SCRIPT to $GPU_IP:$REMOTE_PATH ..."
scp_start_ts=$(date +%s)
scp -o StrictHostKeyChecking=accept-new "$LOCAL_SCRIPT" \
    "${REMOTE_USER}@${GPU_IP}:${REMOTE_PATH}"
scp_end_ts=$(date +%s)
scp_secs=$((scp_end_ts - scp_start_ts))
echo "[+] Script copied (scp: ${scp_secs}s)."

###############################################################################
#  Run remote setup (with progress indicator)
###############################################################################
if [[ "$BACKEND" == "vllm" ]]; then
  echo "[*] Running script on remote GPU (vLLM install and serve; may take a while)..."
else
  echo "[*] Running script on remote GPU (this includes model pull; may take a while)..."
fi
startup_start_ts=$(date +%s)

# Run remote startup in background (pass backend-specific env)
if [[ "$BACKEND" == "vllm" ]]; then
  VLLM_MODEL_ESCAPED=$(echo "$VLLM_MODEL" | sed "s/'/'\\\\''/g")
  HF_TOKEN_ESC=""
  [[ -n "$HF_TOKEN_ARG" ]] && HF_TOKEN_ESC="export HF_TOKEN='$(echo "$HF_TOKEN_ARG" | sed "s/'/'\\\\''/g")'; "
  VLLM_EXTRA_ESC=""
  [[ -n "$VLLM_EXTRA_ARGS_ARG" ]] && VLLM_EXTRA_ESC="export VLLM_EXTRA_ARGS='$(echo "$VLLM_EXTRA_ARGS_ARG" | sed "s/'/'\\\\''/g")'; "
  VLLM_MAX_ESC=""
  [[ -n "$VLLM_MAX_LEN_CLI" ]] && VLLM_MAX_ESC="export VLLM_MAX_MODEL_LEN='$(echo "$VLLM_MAX_LEN_CLI" | sed "s/'/'\\\\''/g")'; "
  VLLM_TRUST_ESC=""
  [[ -n "$VLLM_TRUST_CLI" ]] && VLLM_TRUST_ESC="export VLLM_TRUST_REMOTE_CODE='$(echo "$VLLM_TRUST_CLI" | sed "s/'/'\\\\''/g")'; "
  VLLM_QWEN_STACK_ESC=""
  [[ "$VLLM_NO_QWEN" == true ]] && VLLM_QWEN_STACK_ESC="export VLLM_USE_QWEN3_TOOL_STACK='0'; "
  VLLM_IMAGE_ESC=""
  [[ -n "$VLLM_IMAGE_ARG" ]] && VLLM_IMAGE_ESC="export VLLM_IMAGE='$(echo "$VLLM_IMAGE_ARG" | sed "s/'/'\\\\''/g")'; "
  VLLM_DISABLE_REASONING_ESC=""
  [[ "$VLLM_DISABLE_REASONING_FLAG" == true ]] && VLLM_DISABLE_REASONING_ESC="export VLLM_DISABLE_REASONING='1'; "
  ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" \
    "export VLLM_MODEL='${VLLM_MODEL_ESCAPED}'; export VLLM_PORT='${VLLM_PORT}'; ${VLLM_MAX_ESC}${VLLM_TRUST_ESC}${VLLM_QWEN_STACK_ESC}${VLLM_DISABLE_REASONING_ESC}${VLLM_IMAGE_ESC}${HF_TOKEN_ESC}${VLLM_EXTRA_ESC}chmod +x ${REMOTE_PATH} && sudo -E ${REMOTE_PATH}" &
else
  OLLAMA_MODEL_ESCAPED=$(echo "$OLLAMA_MODEL" | sed "s/'/'\\\\''/g")
  ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" \
    "export OLLAMA_MODEL='${OLLAMA_MODEL_ESCAPED}'; export OLLAMA_PORT='${OLLAMA_PORT}'; chmod +x ${REMOTE_PATH} && sudo -E ${REMOTE_PATH}" &
fi
ssh_pid=$!

# Simple spinner while the remote script is running
spin='-\|/'
i=0
while kill -0 "$ssh_pid" >/dev/null 2>&1; do
  printf "\r[remote] Working... %s" "${spin:i++%${#spin}:1}"
  sleep 1
done

# Wait for SSH to actually finish, capture exit code
wait "$ssh_pid"
startup_end_ts=$(date +%s)
startup_secs=$((startup_end_ts - startup_start_ts))
printf "\r[remote] Startup complete.%-20s\n" ""
echo "[+] Remote deployment and startup script completed (startup: ${startup_secs}s)."

echo "------------------------------------------------------"
echo "[✔] Remote deployment and startup script completed."
echo "------------------------------------------------------"

###############################################################################
#  Open a new terminal window for logs
###############################################################################
if [[ "$BACKEND" == "vllm" ]]; then
  # Single model -> container "vllm"; multiple -> "vllm-8000", "vllm-8001", ...
  if [[ "$VLLM_MODEL" == *,* ]]; then
    FIRST_VLLM_CONTAINER="vllm-${VLLM_PORT}"
  else
    FIRST_VLLM_CONTAINER="vllm"
  fi
fi
if command -v gnome-terminal >/dev/null 2>&1; then
  if [[ "$BACKEND" == "vllm" ]]; then
    echo "[*] Opening new terminal for 'docker logs -f ${FIRST_VLLM_CONTAINER}'..."
    gnome-terminal -- bash -lc \
      "ssh $SSH_OPTS ${REMOTE_USER}@${GPU_IP} 'docker logs -f ${FIRST_VLLM_CONTAINER}'; \
       echo; echo 'vLLM logs ended. Press Enter to close.'; read"
  else
    echo "[*] Opening new terminal for 'docker logs -f ollama'..."
    gnome-terminal -- bash -lc \
      "ssh $SSH_OPTS ${REMOTE_USER}@${GPU_IP} 'docker logs -f ollama'; \
       echo; echo 'Ollama logs ended. Press Enter to close.'; read"
  fi
else
  echo "[!] gnome-terminal not found."
  echo "    To watch logs manually, run:"
  if [[ "$BACKEND" == "vllm" ]]; then
    echo "      ssh ${REMOTE_USER}@${GPU_IP} 'docker logs -f ${FIRST_VLLM_CONTAINER}'"
  else
    echo "      ssh ${REMOTE_USER}@${GPU_IP} 'docker logs -f ollama'"
  fi
fi

###############################################################################
#  Final timing summary (last thing printed)
###############################################################################
script_end_ts=$(date +%s)
total_secs=$((script_end_ts - script_start_ts))

echo "Timing summary (seconds):"
echo "  HotAisle provision : ${provision_secs}s"
echo "  SSH wait           : ${ssh_wait_secs}s"
echo "  Script upload (scp): ${scp_secs}s"
echo "  Remote startup     : ${startup_secs}s"
echo "  TOTAL              : ${total_secs}s"
echo "------------------------------------------------------"
