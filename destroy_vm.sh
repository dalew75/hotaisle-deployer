#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# destroy_vm.sh
#
# Deletes a HotAisle VM by name.
#
# Usage:
#   ./destroy_vm.sh <vm-name>
#     - deletes the named VM
#
#   ./destroy_vm.sh
#     - if no name is provided, uses the last provisioned VM name stored in:
#       ~/.hotaisle_last_vm
#
# Env vars needed:
#   HOTAISLE_TEAM_NAME
#   HOTAISLE_TOKEN
###############################################################################

LAST_VM_FILE="${HOME}/.hotaisle_last_vm"

# Determine VM name: arg wins, else use last-VM file
if [[ $# -ge 1 ]]; then
  VM_NAME="$1"
  SOURCE_DESC="(from argument)"
else
  if [[ -f "$LAST_VM_FILE" ]]; then
    VM_NAME="$(tr -d ' \n\r' < "$LAST_VM_FILE")"
    if [[ -z "$VM_NAME" ]]; then
      echo "ERROR: $LAST_VM_FILE exists but is empty. Please pass a VM name explicitly."
      echo "Usage: $0 <vm-name>"
      exit 1
    fi
    SOURCE_DESC="(from $LAST_VM_FILE)"
  else
    echo "ERROR: No VM name provided and $LAST_VM_FILE does not exist."
    echo "       Run deploy_and_run.sh first (so it records a VM name),"
    echo "       or call this script with an explicit VM name."
    echo
    echo "Usage: $0 <vm-name>"
    exit 1
  fi
fi

# Ensure required environment variables exist
: "${HOTAISLE_TEAM_NAME:?ERROR: HOTAISLE_TEAM_NAME is not set}"
: "${HOTAISLE_TOKEN:?ERROR: HOTAISLE_TOKEN is not set}"

URL="https://admin.hotaisle.app/api/teams/${HOTAISLE_TEAM_NAME}/virtual_machines/${VM_NAME}/"

echo "------------------------------------------------------"
echo "[*] Requesting deletion of VM:"
echo "    - Team: ${HOTAISLE_TEAM_NAME}"
echo "    - VM Name: ${VM_NAME} ${SOURCE_DESC}"
echo "    - URL: ${URL}"
echo "------------------------------------------------------"

# Perform DELETE request and capture HTTP status code
TEMP_RESPONSE_FILE=$(mktemp /tmp/hotaisle_delete_response.XXXXXX)
trap 'rm -f "$TEMP_RESPONSE_FILE"' EXIT
HTTP_STATUS="$(
  curl -s -o "$TEMP_RESPONSE_FILE" -w "%{http_code}" \
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
  # Optionally clear the last VM file if it matches
  if [[ -f "$LAST_VM_FILE" ]]; then
    CURRENT_LAST="$(tr -d ' \n\r' < "$LAST_VM_FILE")"
    if [[ "$CURRENT_LAST" == "$VM_NAME" ]]; then
      rm -f "$LAST_VM_FILE"
      echo "[*] Cleared last-VM record at $LAST_VM_FILE (it referred to this VM)."
      echo "------------------------------------------------------"
    fi
  fi
  exit 0
else
  echo "❌ ERROR: VM delete failed. Status: ${HTTP_STATUS}"
  echo "Returned body:"
  echo "------------------------------------------------------"
  cat "$TEMP_RESPONSE_FILE"
  echo
  echo "------------------------------------------------------"
  exit 1
fi
