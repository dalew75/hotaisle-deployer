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

# --- Wait until the host is SSH-responsive (optional but useful) ------------
echo "[*] Checking if $GPU_IP is reachable via SSH..."
until ssh -o BatchMode=yes -o ConnectTimeout=5 "${REMOTE_USER}@${GPU_IP}" "echo connected" &>/dev/null; do
  echo "[-] Not ready yet... retrying in 3 seconds."
  sleep 3
done
echo "[+] Remote SSH is ready."

# --- Copy script to remote --------------------------------------------------
echo "[*] Copying $LOCAL_SCRIPT to $GPU_IP:$REMOTE_PATH ..."
scp "$LOCAL_SCRIPT" "${REMOTE_USER}@${GPU_IP}:${REMOTE_PATH}"

# --- Run remotely -----------------------------------------------------------
echo "[*] Running script on remote GPU..."
ssh "${REMOTE_USER}@${GPU_IP}" "chmod +x ${REMOTE_PATH} && sudo ${REMOTE_PATH}"

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

# --- Immediately show Ollama logs from remote -------------------------------
echo "[*] Streaming 'docker logs -f ollama' from remote..."
echo "    (Ctrl+C to stop watching logs.)"
ssh "${REMOTE_USER}@${GPU_IP}" "docker logs -f ollama"
