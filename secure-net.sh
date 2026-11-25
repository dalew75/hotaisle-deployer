#!/usr/bin/env bash
# Runs on the REMOTE VM (uploaded by deploy_and_run.sh, run with sudo before the startup script).
#
# Joins the VM to your tailnet so the model API is reachable only over Tailscale.
# The startup scripts then publish their ports on the tailnet IP only (TAILNET_ONLY=1), which is
# what actually keeps the API off the public internet: Docker-published ports bypass ufw.
# ufw is added as a second layer (default deny incoming, SSH allowed, everything on tailscale0 allowed).
#
# Env:
#   TS_AUTHKEY   - required. Use an ephemeral, pre-authorized key tagged e.g. tag:gpu, so the node
#                  disappears from the tailnet when the VM is destroyed.
#   TS_HOSTNAME  - tailnet machine name (default: gpu-hotaisle)

set -euo pipefail

: "${TS_AUTHKEY:?TS_AUTHKEY is required (tailscale auth key)}"
TS_HOSTNAME="${TS_HOSTNAME:-gpu-hotaisle}"

if ! command -v tailscale >/dev/null 2>&1; then
  echo "[*] Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "[*] Joining tailnet as '${TS_HOSTNAME}'..."
tailscale up --authkey "$TS_AUTHKEY" --hostname "$TS_HOSTNAME" --ssh=false --reset

TS_IP="$(tailscale ip -4 | head -n1)"
if [[ -z "$TS_IP" ]]; then
  echo "[!] ERROR: no tailnet IPv4 after 'tailscale up'."
  exit 1
fi
echo "[+] Tailnet IP: $TS_IP"

if command -v ufw >/dev/null 2>&1 || apt-get install -y ufw >/dev/null 2>&1; then
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow in on tailscale0 >/dev/null
  ufw --force enable >/dev/null
  echo "[+] ufw: deny incoming except SSH and tailscale0."
else
  echo "[!] ufw not available; relying on tailnet-only port binding."
fi
