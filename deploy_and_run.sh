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
#
#  Network (default: tailnet only): TS_AUTHKEY must be set. secure-net.sh joins the VM to your tailnet
#  (name TS_HOSTNAME, default gpu-hotaisle-<vm>) and the API ports are published on the tailnet IP only.
#  --public: skip Tailscale and publish on all interfaces (no auth: anyone with the IP can use it).
#  Secrets (TS_AUTHKEY, HF token) go to the VM in a mode-600 env file that is deleted after it is read,
#  never on the SSH command line.
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
PUBLIC=false
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
    --public)
      PUBLIC=true
      shift
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

# Tailnet-only unless --public (checked before anything is provisioned or billed)
if [[ "$PUBLIC" == true ]]; then
  echo "[!] WARNING: --public: the model API will be open on the VM's public IP with no auth."
elif [[ -z "${TS_AUTHKEY:-}" ]]; then
  echo "[!] ERROR: TS_AUTHKEY is not set. The API is only exposed over Tailscale by default."
  echo "    Create an ephemeral, pre-authorized auth key (tag e.g. tag:gpu) and export TS_AUTHKEY,"
  echo "    or pass --public to expose it on the public IP without auth (not recommended)."
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
#  Tailnet name for this VM
###############################################################################
TS_HOSTNAME="${TS_HOSTNAME:-gpu-hotaisle${VM_NAME:+-$VM_NAME}}"
TS_HOSTNAME="$(echo "$TS_HOSTNAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n-' '-' | cut -c1-63)"

###############################################################################
#  Build the remote env file (mode 600; secrets never on the SSH command line)
###############################################################################
ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/hotaisle_env.XXXXXX")"
chmod 600 "$ENV_FILE"
trap 'rm -f "$ENV_FILE"' EXIT
add_env() { printf 'export %s=%q\n' "$1" "$2" >> "$ENV_FILE"; }

if [[ "$PUBLIC" == true ]]; then
  add_env TAILNET_ONLY 0
else
  add_env TAILNET_ONLY 1
  add_env TS_AUTHKEY "$TS_AUTHKEY"
  add_env TS_HOSTNAME "$TS_HOSTNAME"
fi
if [[ "$BACKEND" == "vllm" ]]; then
  add_env VLLM_MODEL "$VLLM_MODEL"
  add_env VLLM_PORT "$VLLM_PORT"
  [[ -n "$VLLM_MAX_LEN_CLI" ]] && add_env VLLM_MAX_MODEL_LEN "$VLLM_MAX_LEN_CLI"
  [[ -n "$VLLM_TRUST_CLI" ]] && add_env VLLM_TRUST_REMOTE_CODE "$VLLM_TRUST_CLI"
  [[ "$VLLM_NO_QWEN" == true ]] && add_env VLLM_USE_QWEN3_TOOL_STACK 0
  [[ "$VLLM_DISABLE_REASONING_FLAG" == true ]] && add_env VLLM_DISABLE_REASONING 1
  [[ -n "$VLLM_IMAGE_ARG" ]] && add_env VLLM_IMAGE "$VLLM_IMAGE_ARG"
  [[ -n "$HF_TOKEN_ARG" ]] && add_env HF_TOKEN "$HF_TOKEN_ARG"
  [[ -n "$VLLM_EXTRA_ARGS_ARG" ]] && add_env VLLM_EXTRA_ARGS "$VLLM_EXTRA_ARGS_ARG"
else
  add_env OLLAMA_MODEL "$OLLAMA_MODEL"
  add_env OLLAMA_PORT "$OLLAMA_PORT"
fi

###############################################################################
#  Upload startup script, secure-net.sh and the env file
###############################################################################
REMOTE_DIR="/home/${REMOTE_USER}"
REMOTE_ENV="${REMOTE_DIR}/.deploy.env"
REMOTE_NET="${REMOTE_DIR}/secure-net.sh"
echo "[*] Copying $LOCAL_SCRIPT, secure-net.sh and env to $GPU_IP ..."
scp_start_ts=$(date +%s)
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" "umask 077; : > ${REMOTE_ENV}"
scp -q -o StrictHostKeyChecking=accept-new "$ENV_FILE" "${REMOTE_USER}@${GPU_IP}:${REMOTE_ENV}"
scp -q -o StrictHostKeyChecking=accept-new "$LOCAL_SCRIPT" "${REMOTE_USER}@${GPU_IP}:${REMOTE_PATH}"
scp -q -o StrictHostKeyChecking=accept-new "secure-net.sh" "${REMOTE_USER}@${GPU_IP}:${REMOTE_NET}"
scp_end_ts=$(date +%s)
scp_secs=$((scp_end_ts - scp_start_ts))
echo "[+] Files copied (scp: ${scp_secs}s)."

###############################################################################
#  Run remote setup (with progress indicator)
###############################################################################
if [[ "$BACKEND" == "vllm" ]]; then
  echo "[*] Running script on remote GPU (vLLM install and serve; may take a while)..."
else
  echo "[*] Running script on remote GPU (this includes model pull; may take a while)..."
fi
startup_start_ts=$(date +%s)

# The env file is read into the shell and deleted before anything else runs.
NET_STEP=""
[[ "$PUBLIC" == true ]] || NET_STEP="sudo -E ${REMOTE_NET} && "
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" \
  "set -a; . ${REMOTE_ENV}; set +a; rm -f ${REMOTE_ENV}; chmod +x ${REMOTE_PATH} ${REMOTE_NET} && ${NET_STEP}sudo -E ${REMOTE_PATH}" &
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

if [[ "$PUBLIC" == true ]]; then
  echo "[!] API is PUBLIC on ${GPU_IP} (no auth)."
else
  FIRST_PORT="${VLLM_PORT:-$OLLAMA_PORT}"
  echo "[+] API (tailnet only): http://${TS_HOSTNAME}:${FIRST_PORT}/v1"
fi
echo "Timing summary (seconds):"
echo "  HotAisle provision : ${provision_secs}s"
echo "  SSH wait           : ${ssh_wait_secs}s"
echo "  Script upload (scp): ${scp_secs}s"
echo "  Remote startup     : ${startup_secs}s"
echo "  TOTAL              : ${total_secs}s"
echo "------------------------------------------------------"
