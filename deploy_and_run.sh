#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  deploy_and_run.sh
#
#  1. Optionally provisions a new HotAisle VM (if no IP provided)
#  2. Extracts SSH IP from the HotAisle response
#  3. Cleans host keys for that IP
#  4. Uploads startup-amd.sh to the VM
#  5. Runs it remotely via sudo
#  6. Opens a new terminal window streaming docker logs -f ollama
###############################################################################

REMOTE_USER="hotaisle"
REMOTE_PATH="/home/hotaisle/start.sh"
LOCAL_SCRIPT="startup-amd.sh"
KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"

# Optional argument: GPU IP address (skip provisioning if provided)
GPU_IP="${1:-}"

echo "------------------------------------------------------"
echo "[*] Local startup script: $LOCAL_SCRIPT"
echo "[*] Provided GPU IP (if any): ${GPU_IP:-<none>}"
echo "------------------------------------------------------"

###############################################################################
#  Ensure startup-amd.sh exists locally
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

  # Optional user-data file (cloud-init)
  HOTAISLE_USER_DATA_URL="${HOTAISLE_USER_DATA_URL:-}"

  # Build payload from known working VM specs
  read -r -d '' PAYLOAD <<JSON
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

  echo "[*] POSTing payload to HotAisle..."
  RESPONSE="$(
    curl -sS -X POST \
      "https://admin.hotaisle.app/api/teams/${HOTAISLE_TEAM_NAME}/virtual_machines/" \
      -H "accept: application/json" \
      -H "Authorization: Token ${HOTAISLE_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD"
  )"

  echo "------------------------------------------------------"
  echo "[*] HotAisle provision response:"
  echo "$RESPONSE" | jq . || echo "$RESPONSE"
  echo "------------------------------------------------------"

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

  echo "[+] Provisioned GPU VM IP: $GPU_IP"
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
until ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" "echo connected" &>/dev/null; do
  echo "[-] Not ready yet... retrying in 3 seconds."
  sleep 3
done
echo "[+] Remote SSH is ready."

###############################################################################
#  Upload startup-amd.sh
###############################################################################
echo "[*] Copying $LOCAL_SCRIPT to $GPU_IP:$REMOTE_PATH ..."
scp -o StrictHostKeyChecking=accept-new "$LOCAL_SCRIPT" \
    "${REMOTE_USER}@${GPU_IP}:${REMOTE_PATH}"

###############################################################################
#  Run remote setup
###############################################################################
echo "[*] Running script on remote GPU..."
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" \
  "chmod +x ${REMOTE_PATH} && sudo ${REMOTE_PATH}"

echo "------------------------------------------------------"
echo "[✔] Remote deployment and startup script completed."
echo "------------------------------------------------------"

###############################################################################
#  Open a new terminal window and stream docker logs -f ollama
###############################################################################
if command -v gnome-terminal >/dev/null 2>&1; then
  echo "[*] Opening new terminal for 'docker logs -f ollama'..."
  gnome-terminal -- bash -lc \
    "ssh $SSH_OPTS ${REMOTE_USER}@${GPU_IP} 'docker logs -f ollama'; \
     echo; echo 'Ollama logs ended. Press Enter to close.'; read"
else
  echo "[!] gnome-terminal not found."
  echo "    To watch logs manually, run:"
  echo "      ssh ${REMOTE_USER}@${GPU_IP} 'docker logs -f ollama'"
fi
