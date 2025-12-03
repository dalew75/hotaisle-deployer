#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# destroy_vm.sh
#
# Deletes a HotAisle VM by name.
# Usage: ./destroy_vm.sh <vm-name>
#
# Env vars needed:
#   HOTAISLE_TEAM_NAME
#   HOTAISLE_TOKEN
###############################################################################

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <vm-name>"
  echo "Example: $0 enc1-gpuvm028"
  exit 1
fi

VM_NAME="$1"

# Ensure required environment variables exist
: "${HOTAISLE_TEAM_NAME:?ERROR: HOTAISLE_TEAM_NAME is not set}"
: "${HOTAISLE_TOKEN:?ERROR: HOTAISLE_TOKEN is not set}"

URL="https://admin.hotaisle.app/api/teams/${HOTAISLE_TEAM_NAME}/virtual_machines/${VM_NAME}/"

echo "------------------------------------------------------"
echo "[*] Requesting deletion of VM:"
echo "    - Team: ${HOTAISLE_TEAM_NAME}"
echo "    - VM Name: ${VM_NAME}"
echo "    - URL: ${URL}"
echo "------------------------------------------------------"

# Perform DELETE request and capture HTTP status code
HTTP_STATUS="$(
  curl -s -o /tmp/hotaisle_delete_response.txt -w "%{http_code}" \
    -X DELETE \
    "$URL" \
    -H "accept: application/json" \
    -H "Authorization: Token ${HOTAISLE_TOKEN}"
)"

echo "------------------------------------------------------"
echo "[*] HotAisle Response Status: ${HTTP_STATUS}"
echo "------------------------------------------------------"

if [[ "$HTTP_STATUS" == "204" ]]; then
  echo "🎉 SUCCESS: VM '${VM_NAME}' was deleted (HTTP 204)."
  echo "Nothing returned in body, as expected."
  echo "------------------------------------------------------"
  exit 0
else
  echo "❌ ERROR: VM delete failed. Status: ${HTTP_STATUS}"
  echo "Returned body:"
  echo "------------------------------------------------------"
  cat /tmp/hotaisle_delete_response.txt
  echo
  echo "------------------------------------------------------"
  exit 1
fi
