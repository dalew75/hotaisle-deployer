#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# idle_stop.sh  (HA-103, D2 = (b): the workstation polls and deletes)
#
# Run from cron on the workstation every 5 minutes. For each VM that
# deploy_and_run.sh recorded, it asks the model API over the tailnet whether
# anything happened, and deletes the VM (via destroy_vm.sh) when:
#   - no API requests for IDLE_MINUTES (default 30), or
#   - the API never came up within BOOT_GRACE_MINUTES (default 90), or
#   - the VM is older than MAX_HOURS (default 4), busy or not (warned 15 min before).
# Never deletes inside HotAisle's minimum reservation (no saving, and a forced
# delete forfeits the minimum charge). Only reads request counters, never prompts.
#
# Usage:
#   ./idle_stop.sh             one pass (what cron runs)
#   ./idle_stop.sh --dry-run   one pass, decide and print, delete nothing
#   ./idle_stop.sh --status    print each recorded VM's age and idle time
#
# Cron (workstation):
#   */5 * * * * ~/dev/github/dalew75/hotaisle-deployer/idle_stop.sh >/dev/null 2>&1
#
# Env: IDLE_MINUTES, MAX_HOURS, BOOT_GRACE_MINUTES, CAP_WARN_MINUTES,
#      HOTAISLE_SECRETS (default ~/.config/hotaisle/secrets.sh: HOTAISLE_TEAM_NAME, HOTAISLE_TOKEN)
###############################################################################

IDLE_MINUTES="${IDLE_MINUTES:-30}"
MAX_HOURS="${MAX_HOURS:-4}"
BOOT_GRACE_MINUTES="${BOOT_GRACE_MINUTES:-90}"
CAP_WARN_MINUTES="${CAP_WARN_MINUTES:-15}"
STATE_DIR="${HOTAISLE_STATE_DIR:-$HOME/.local/state/hotaisle-deployer}"
VM_DIR="$STATE_DIR/vms"
LOG="$STATE_DIR/idle-stop.log"
SECRETS="${HOTAISLE_SECRETS:-$HOME/.config/hotaisle/secrets.sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
API_BASE="${HOTAISLE_API:-https://admin.hotaisle.app/api}"   # overridable for tests

MODE=run
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --status) MODE=status ;;
  "") ;;
  -h|--help) sed -n '4,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "Unknown option: $1"; exit 2 ;;
esac

mkdir -p "$VM_DIR"
exec 9>"$STATE_DIR/idle-stop.lock"
flock -n 9 || exit 0   # a previous pass is still running

now=$(date +%s)
log() { echo "$(date -Is) $*" >>"$LOG"; [[ "$MODE" != run ]] && echo "$*"; return 0; }

# ---- voice line + popup: same NATS path as ai-gateway bin/gpu-capacity ------------------
json_str() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
nats_pub() {
  local subject="$1" payload="$2"
  (
    set -a
    # shellcheck source=/dev/null
    . "${NATS_CREDENTIALS_FILE:-$HOME/.config/nats/credentials.env}" 2>/dev/null
    set +a
    exec 3<>"/dev/tcp/${NATS_HOST:-localhost}/${NATS_PORT:-4222}" || exit 1
    printf 'CONNECT {"verbose":false,"name":"hotaisle-idle-stop","user":%s,"pass":%s}\r\nPUB %s %d\r\n%s\r\nPING\r\n' \
      "$(json_str "${NATS_USER:-}")" "$(json_str "${NATS_PASS:-${NATS_PASSWORD:-}}")" \
      "$subject" "$(printf '%s' "$payload" | wc -c)" "$payload" >&3
    [[ "$(timeout 3 grep -m1 -aE '^(PONG|-ERR)' <&3)" == PONG* ]]
  ) 2>/dev/null
}
alert() { # <title> <text> <hint>
  [[ "$MODE" == run ]] || { echo "(would announce) $1: $2"; return 0; }
  local at; at=$(date -Is)
  nats_pub message.received "$(jq -cn --arg title "$1" --arg text "$2" --arg hint "$3" --arg at "$at" \
    '{platform: "hotaisle", platformName: "HotAisle GPU", icon: "🖥️", kind: "other",
      id: "hotaisle-idle:\($at)", from: "idle-stop", title: $title, text: $text, speakText: $text,
      hint: $hint, at: $at}')" || log "publish failed (local NATS down?): $1"
}

# ---- per-VM record helpers -----------------------------------------------------------------
rec_get() { jq -r "$2 // empty" "$1"; }
rec_set() { # <file> <jq filter> [jq args...]
  local f="$1" filter="$2"; shift 2
  local tmp; tmp=$(mktemp "$f.XXXX") && jq "$@" "$filter" "$f" >"$tmp" && mv "$tmp" "$f"
}

# Activity probe over the tailnet. Prints "<reachable 0|1> <busy 0|1> <counter>".
probe() {
  local f="$1" host backend ports p reach=0 busy=0 counter=0 body
  host=$(rec_get "$f" .host); backend=$(rec_get "$f" .backend)
  mapfile -t ports < <(jq -r '.ports[]?' "$f")
  for p in "${ports[@]}"; do
    if [[ "$backend" == vllm ]]; then
      body=$(curl -sf --max-time 8 "http://$host:$p/metrics") || continue
      reach=1
      # Finished requests (counter) and requests in flight
      counter=$(( counter + $(awk '/^vllm:request_success_total/{s+=$NF} END{printf "%d", s}' <<<"$body") ))
      [[ "$(awk '/^vllm:num_requests_running/{s+=$NF} END{printf "%d", s}' <<<"$body")" -gt 0 ]] && busy=1
    else
      # Ollama keeps a model loaded for 5 min (keep_alive) after each request, so "a model is loaded" = recent use
      body=$(curl -sf --max-time 8 "http://$host:$p/api/ps") || continue
      reach=1
      [[ "$(jq '(.models // []) | length' <<<"$body" 2>/dev/null || echo 0)" -gt 0 ]] && busy=1
    fi
  done
  echo "$reach $busy $counter"
}

vm_exists() { # 0 = exists, 1 = gone (404), 2 = unknown (API error)
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "${API_BASE}/teams/${HOTAISLE_TEAM_NAME}/virtual_machines/$1/" \
    -H "accept: application/json" -H "Authorization: Token ${HOTAISLE_TOKEN}")
  case "$code" in 200) return 0 ;; 404) return 1 ;; *) return 2 ;; esac
}

delete_vm() { # <record file> <name> <reason>
  local f="$1" name="$2" reason="$3"
  if [[ "$MODE" != run ]]; then
    echo "(would delete) $name: $reason"
    return 0
  fi
  log "deleting $name: $reason"
  DELETED+=" $name "
  if "$HERE/destroy_vm.sh" "$name" >>"$LOG" 2>&1; then
    rm -f "$f"
    alert "GPU VM stopped" "HotAisle VM stopped: $reason." later
  else
    log "delete FAILED for $name"
    alert "GPU VM delete failed" "Could not delete HotAisle VM $name. It may still be billing. Run destroy_vm.sh." urgent
  fi
}

DELETED=""   # deleted this pass; the team listing can still show them for a moment
shopt -s nullglob
records=("$VM_DIR"/*.json)

if [[ "$MODE" == status ]]; then
  [[ ${#records[@]} -eq 0 ]] && { echo "No recorded VMs."; exit 0; }
  printf '%-28s %-7s %8s %8s %s\n' VM BACKEND AGE IDLE ENDPOINT
  for f in "${records[@]}"; do
    c=$(rec_get "$f" .created_at); la=$(rec_get "$f" .last_activity)
    printf '%-28s %-7s %7sm %7s %s\n' "$(rec_get "$f" .name)" "$(rec_get "$f" .backend)" \
      $(( (now - c) / 60 )) "$([[ -n "$la" ]] && echo "$(( (now - la) / 60 ))m" || echo "not up")" \
      "http://$(rec_get "$f" .host):$(jq -r '.ports[0] // ""' "$f")"
  done
  exit 0
fi

# Secrets: only needed when there is something to check
# shellcheck source=/dev/null
if [[ -f "$SECRETS" ]]; then set -a; . "$SECRETS"; set +a; fi
: "${HOTAISLE_TEAM_NAME:?HOTAISLE_TEAM_NAME is not set (see $SECRETS)}"
: "${HOTAISLE_TOKEN:?HOTAISLE_TOKEN is not set (see $SECRETS)}"
export HOTAISLE_TEAM_NAME HOTAISLE_TOKEN

for f in "${records[@]}"; do
  name=$(rec_get "$f" .name)
  [[ -n "$name" ]] || continue

  vm_exists "$name"; ex=$?
  if [[ $ex -eq 1 ]]; then
    log "$name no longer exists on HotAisle; dropping its record"
    [[ "$MODE" == run ]] && rm -f "$f"
    continue
  fi
  # ex=2 (API error): carry on; destroy_vm.sh will report if the delete fails

  created=$(rec_get "$f" .created_at)
  min_res=$(rec_get "$f" .min_reservation_minutes); min_res=${min_res:-0}
  age_min=$(( (now - created) / 60 ))

  read -r reach busy counter < <(probe "$f")
  last=$(rec_get "$f" .last_activity)
  prev=$(rec_get "$f" .last_counter)
  if [[ "$reach" == 1 ]]; then
    if [[ -z "$last" || "$busy" == 1 || "$counter" != "${prev:-$counter}" ]]; then
      last=$now   # first time up, a request in flight, or the request counter moved
    fi
    # shellcheck disable=SC2016  # $la and $c are jq variables
    [[ "$MODE" == run ]] && rec_set "$f" '.last_activity = $la | .last_counter = $c' \
      --argjson la "$last" --arg c "$counter"
  fi

  reason=""
  if (( age_min >= MAX_HOURS * 60 )); then
    reason="reached the ${MAX_HOURS} hour cap"
  elif [[ -z "$last" ]]; then
    (( age_min >= BOOT_GRACE_MINUTES )) && reason="its API never came up in ${BOOT_GRACE_MINUTES} minutes"
  else
    idle_min=$(( (now - last) / 60 ))
    (( idle_min >= IDLE_MINUTES )) && reason="idle for ${idle_min} minutes"
  fi

  log "$name age=${age_min}m reach=$reach busy=$busy counter=$counter idle=$([[ -n "$last" ]] && echo "$(( (now - last) / 60 ))m" || echo "not-up")${reason:+ -> $reason}"

  if [[ -n "$reason" ]]; then
    if (( age_min < min_res )); then
      log "$name: within the ${min_res}-minute minimum reservation; deleting once it ends"
      continue
    fi
    delete_vm "$f" "$name" "$reason"
    continue
  fi

  # One warning before the hard cap
  if (( age_min >= MAX_HOURS * 60 - CAP_WARN_MINUTES )) && [[ "$(rec_get "$f" .cap_warned)" != true ]]; then
    alert "GPU VM stops soon" "HotAisle VM reaches its ${MAX_HOURS} hour cap in about ${CAP_WARN_MINUTES} minutes and will be deleted." soon
    [[ "$MODE" == run ]] && rec_set "$f" '.cap_warned = true'
  fi
done

# VMs on the team that this tool didn't create: announce once, never delete.
list=$(curl -sf --max-time 15 "${API_BASE}/teams/${HOTAISLE_TEAM_NAME}/virtual_machines/" \
  -H "accept: application/json" -H "Authorization: Token ${HOTAISLE_TOKEN}") || exit 0
while read -r vm; do
  [[ -z "$vm" || -f "$VM_DIR/$vm.json" || -f "$STATE_DIR/unmanaged-$vm" || "$DELETED" == *" $vm "* ]] && continue
  log "unmanaged VM on the team: $vm (not deleting)"
  alert "Unmanaged GPU VM" "A HotAisle VM that idle-stop doesn't manage is running on your team. Check the console." soon
  [[ "$MODE" == run ]] && touch "$STATE_DIR/unmanaged-$vm"
done < <(jq -r '.[]?.name // empty' <<<"$list" 2>/dev/null)
exit 0
