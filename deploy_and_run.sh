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
#  Usage: ./deploy_and_run.sh [--vllm] [--model <model>] [--hf-token <token>] [GPU_IP]
#  Without --vllm: deploy Ollama (--model is Ollama model, e.g. llama3.2:3b).
#  With --vllm:    deploy vLLM (--model must be a Hugging Face ID, e.g. Qwen/Qwen2.5-72B-Instruct).
#                  Use --hf-token for gated models.
#  Example: ./deploy_and_run.sh --model llama3.2:3b
#           ./deploy_and_run.sh --vllm --model Qwen/Qwen2.5-72B-Instruct
#           ./deploy_and_run.sh --vllm --model Qwen/Qwen3.5-122B-A10B --hf-token hf_xxx  (note: A10B not A1B0)
#           ./deploy_and_run.sh --vllm --model Qwen/Qwen2.5-72B-Instruct --hf-token hf_xxx 192.168.1.10
###############################################################################

REMOTE_USER="${REMOTE_USER:-hotaisle}"
REMOTE_PATH="/home/${REMOTE_USER}/start.sh"
KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"
LAST_VM_FILE="${HOME}/.hotaisle_last_vm"

# Parse arguments: --vllm, --model <name>, --hf-token <token>, then optional GPU_IP
BACKEND="ollama"
MODEL_ARG=""
HF_TOKEN_ARG=""
while [[ $# -gt 0 ]] && [[ "$1" == -* ]]; do
  case "$1" in
    --vllm)
      BACKEND="vllm"
      shift
      ;;
    --model)
      MODEL_ARG="$2"
      shift 2
      ;;
    --hf-token)
      HF_TOKEN_ARG="$2"
      shift 2
      ;;
    *)
      echo "[!] Unknown option: $1"
      exit 1
      ;;
  esac
done
GPU_IP="${1:-}"

# Set script and model by backend
if [[ "$BACKEND" == "vllm" ]]; then
  LOCAL_SCRIPT="startup-vllm.sh"
  VLLM_MODEL="${MODEL_ARG:-Qwen/Qwen2.5-VL-72B-Instruct}"
  OLLAMA_MODEL=""
  # vLLM expects a Hugging Face model ID (e.g. Qwen/Qwen2.5-72B-Instruct), not an Ollama tag (e.g. qwen3.5:122b)
  if [[ -n "$MODEL_ARG" && "$MODEL_ARG" == *:* && "$MODEL_ARG" != */* ]]; then
    echo "[!] ERROR: With --vllm, --model must be a Hugging Face model ID (e.g. Qwen/Qwen2.5-72B-Instruct), not an Ollama tag."
    echo "    You passed: $MODEL_ARG"
    echo "    Use format: org/model-name (e.g. Qwen/Qwen2.5-72B-Instruct or Qwen/Qwen2.5-VL-7B-Instruct)."
    exit 1
  fi
else
  LOCAL_SCRIPT="startup-amd.sh"
  OLLAMA_MODEL="${MODEL_ARG:-}"
  VLLM_MODEL=""
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
  echo "[*] vLLM model:       $VLLM_MODEL"
  if [[ -n "$HF_TOKEN_ARG" ]]; then
    echo "[*] HF token:         (set)"
  fi
else
  if [[ -n "$OLLAMA_MODEL" ]]; then
    echo "[*] Ollama model:     $OLLAMA_MODEL"
  else
    echo "[*] Ollama model:     (default: gpt-oss:120b from startup-amd.sh)"
  fi
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

# Run remote startup in background (pass model and optional HF token via env for backend)
if [[ "$BACKEND" == "vllm" ]]; then
  VLLM_MODEL_ESCAPED=$(echo "$VLLM_MODEL" | sed "s/'/'\\\\''/g")
  HF_TOKEN_ESC=""
  [[ -n "$HF_TOKEN_ARG" ]] && HF_TOKEN_ESC="export HF_TOKEN='$(echo "$HF_TOKEN_ARG" | sed "s/'/'\\\\''/g")'; "
  ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" \
    "export VLLM_MODEL='${VLLM_MODEL_ESCAPED}'; ${HF_TOKEN_ESC}chmod +x ${REMOTE_PATH} && sudo -E ${REMOTE_PATH}" &
elif [[ -n "$OLLAMA_MODEL" ]]; then
  OLLAMA_MODEL_ESCAPED=$(echo "$OLLAMA_MODEL" | sed "s/'/'\\\\''/g")
  ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" \
    "export MODEL_NAME='${OLLAMA_MODEL_ESCAPED}'; chmod +x ${REMOTE_PATH} && sudo -E ${REMOTE_PATH}" &
else
  ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" \
    "chmod +x ${REMOTE_PATH} && sudo ${REMOTE_PATH}" &
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
if command -v gnome-terminal >/dev/null 2>&1; then
  if [[ "$BACKEND" == "vllm" ]]; then
    echo "[*] Opening new terminal for 'docker logs -f vllm'..."
    gnome-terminal -- bash -lc \
      "ssh $SSH_OPTS ${REMOTE_USER}@${GPU_IP} 'docker logs -f vllm'; \
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
    echo "      ssh ${REMOTE_USER}@${GPU_IP} 'docker logs -f vllm'"
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
