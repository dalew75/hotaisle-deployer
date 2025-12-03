#!/usr/bin/env bash
set -euo pipefail

# --- Argument check ---------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <GPU_IP_ADDRESS>"
  exit 1
fi

GPU_IP="$1"
REMOTE_USER="hotaisle"
REMOTE_PATH="/home/hotaisle/start.sh"
LOCAL_SCRIPT="startup-amd.sh"
KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"

echo "------------------------------------------------------"
echo "[*] Deploying to GPU instance at: $GPU_IP"
echo "[*] Remote user: $REMOTE_USER"
echo "[*] Local script: $LOCAL_SCRIPT"
echo "[*] Remote script: $REMOTE_PATH"
echo "------------------------------------------------------"

# --- Ensure local script exists ---------------------------------------------
if [[ ! -f "$LOCAL_SCRIPT" ]]; then
  echo "[!] ERROR: Local script '$LOCAL_SCRIPT' not found."
  exit 1
fi

# --- Clean up old SSH host keys for this IP ---------------------------------
echo "[*] Cleaning old SSH host keys for ${GPU_IP} (if any)..."
if [[ -f "$KNOWN_HOSTS_FILE" ]]; then
  ssh-keygen -f "$KNOWN_HOSTS_FILE" -R "$GPU_IP" >/dev/null 2>&1 || true
  ssh-keygen -f "$KNOWN_HOSTS_FILE" -R "[$GPU_IP]" >/dev/null 2>&1 || true
fi

# Common SSH options: auto-accept new host key, timeout for retries
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

# --- Wait until the host is SSH-responsive ----------------------------------
echo "[*] Checking if $GPU_IP is reachable via SSH..."
until ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" "echo connected" &>/dev/null; do
  echo "[-] Not ready yet... retrying in 3 seconds."
  sleep 3
done
echo "[+] Remote SSH is ready."

# --- Copy script to remote --------------------------------------------------
echo "[*] Copying $LOCAL_SCRIPT to $GPU_IP:$REMOTE_PATH ..."
scp -o StrictHostKeyChecking=accept-new "$LOCAL_SCRIPT" "${REMOTE_USER}@${GPU_IP}:${REMOTE_PATH}"

# --- Run remotely -----------------------------------------------------------
echo "[*] Running script on remote GPU..."
ssh $SSH_OPTS "${REMOTE_USER}@${GPU_IP}" "chmod +x ${REMOTE_PATH} && sudo ${REMOTE_PATH}"

echo "------------------------------------------------------"
echo "[✔] Remote deployment and startup script completed."
echo "------------------------------------------------------"

# --- Print TypingMind custom model JSON ------------------------------------
echo
echo "Paste this JSON into TypingMind's custom model config:"
echo "------------------------------------------------------"
cat <<EOF
{
  "title": "HotAisle:OSS",
  "description": "",
  "iconUrl": "",
  "endpoint": "http://$GPU_IP:11434/v1/chat/completions",
  "id": "4445c4db-8527-44bf-98b1-62ac43b52382",
  "modelID": "gpt-oss:120b",
  "apiType": "openai",
  "contextLength": 4096,
  "headerRows": [],
  "bodyRows": [],
  "skipAPIKey": true,
  "pluginSupported": false,
  "visionSupported": false,
  "systemMessageSupported": true,
  "streamOutputSupported": true,
  "supportedParameters": [
    "temperature",
    "presencePenalty",
    "frequencyPenalty",
    "topP",
    "maxTokens",
    "contextLimit",
    "reasoningEffort"
  ],
  "pricePerMillionTokens": {
    "prompt": null,
    "completion": null
  }
}
EOF
echo "------------------------------------------------------"
echo

# --- Open a NEW terminal window for Ollama logs -----------------------------
if command -v gnome-terminal >/dev/null 2>&1; then
  echo "[*] Opening new terminal window to stream 'docker logs -f ollama'..."
  gnome-terminal -- bash -lc "ssh $SSH_OPTS ${REMOTE_USER}@${GPU_IP} 'docker logs -f ollama'; echo; echo 'Ollama logs session ended. Press Enter to close.'; read"
else
  echo "[!] Could not find gnome-terminal."
  echo "    To watch logs manually, run this in another terminal:"
  echo "    ssh $SSH_OPTS ${REMOTE_USER}@${GPU_IP} 'docker logs -f ollama'"
fi
