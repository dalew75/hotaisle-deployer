# hotaisle-deployer backlog

Built from the code and the 2026-11-25 setup session, checked against the code at `1535453`. This is the
one place for planned work. Nothing here is approved for building until the owner says so.

**How to use it.** IDs are stable (`HA-<epic><nn>`): never reuse or renumber them. Status moves
`Proposed` → `Approved` → `In progress` → `Done (<sha>)`, or `Investigate` / `Needs decision` /
`Won't do (<why>)`. Close an item by editing its status, not by deleting it.

**Priority.** P0 critical stability · P1 core usability and correctness · P2 polish · P3 major features ·
P4 long-term. **Size.** S = under an hour or two, M = a session, L = several sessions, XL = a milestone.

**Rules that shape many items** (from `AGENTS.md`): every paid run needs the owner's go-ahead; tailnet only
by default; provider-specific knowledge lives here, generic lifecycle logic in `../ai-gateway`.

---

## A. What the code does today

| Area | What exists | Where |
|---|---|---|
| Provisioning | POSTs a fixed 1× MI300X spec (13 cores, 240 GB RAM, 12 TB) to the HotAisle API; saves the VM name | `deploy_and_run.sh` |
| Destroy | DELETE by name, default from `~/.hotaisle_last_vm`; 204 = success | `destroy_vm.sh` |
| Backends | `--backend ollama` (one port, several models) or `vllm` (one container per model, PORT, PORT+1…) | `startup-ollama.sh`, `startup-vllm.sh` |
| vLLM tuning | max-model-len (131072), trust-remote-code, Qwen3 tool stack, reasoning off, image override, extra args | `startup-vllm.sh` |
| Network | tailnet only by default (TS_AUTHKEY required, ports bound to the tailnet IP, ufw); `--public` opt-out | `secure-net.sh`, startup scripts |
| Secrets | mode-600 env file, sourced and deleted on the VM | `deploy_and_run.sh` |
| Capacity | checks `virtual_machines/available/` before creating; exits 2 when none | `deploy_and_run.sh` |
| Waiting | SSH retry loop with no timeout; spinner while the remote script runs (no progress) | `deploy_and_run.sh` |
| Logs | opens `gnome-terminal` with `docker logs -f` when available | `deploy_and_run.sh` |
| Cost tracking | none | — |
| Idle stop | none; a forgotten VM bills until destroyed | — |
| Machine-readable output | none (human text only) | — |

---

## B. Prioritized roadmap

**P0: critical stability**

| ID | Title | Type | Size |
|---|---|---|---|
| HA-101 | First paid run of the tailnet-only path | Test | S |
| HA-103 | Idle auto-stop on the VM | Feature | M |

**P1: core usability and correctness**

| ID | Title | Type | Size |
|---|---|---|---|
| HA-102 | Lifecycle contract: `up / status / down / cost` with JSON output | Feature | M |
| HA-106 | Spend log and monthly ceiling | Feature | S |
| HA-109 | Timeouts: SSH wait and model pull | Bug | S |
| HA-110 | Readiness check: wait until `/v1/models` answers | Feature | S |

**P2:** HA-105 deploy-notify voice lines · HA-107 pin the vLLM image · HA-108 drop gnome-terminal coupling ·
HA-111 shellcheck clean.
**P3:** HA-104 keep model weights between VMs (cold start) · HA-112 VM size choice (2×/4×/8× MI300X).

**Why this order.** HA-101 proves the security fix before anyone relies on it. HA-103 removes the biggest
money risk (a forgotten VM). HA-102 is what ai-gateway needs to drive this repo; HA-106/109/110 make it
safe to drive unattended.

---

## C. Technical findings for bugs

### HA-109 Timeouts: SSH wait and model pull

- **Evidence (code):** `until ssh … "echo connected"` loops forever; a VM that never comes up keeps the
  script (and the bill) running with no end.
- **Tests:** point it at an unroutable IP with a short timeout; it must exit non-zero and say so.

---

## D. Proposed sprint

Goal: safe to start and stop from ai-gateway, with no way to forget a running VM. About 3 sessions.

1. **HA-101 First paid run of the tailnet-only path** (S). One short run on the cheapest model. *Verify:*
   API answers on the tailnet name, not on the public IP (`curl` from outside times out), VM leaves the
   tailnet after destroy.
2. **HA-103 Idle auto-stop** (M). The workstation polls over the tailnet and deletes after N idle minutes (D2 = b). *Verify:*
   with N=5, the VM is gone ~5 min after the last request.
3. **HA-102 Lifecycle contract** (M). `hotaisle up|status|down|cost --json`. *Verify:* ai-gateway can parse
   every command; `status` matches the HotAisle API.
4. **HA-106 Spend log + ceiling** and **HA-109 timeouts** (S each).

Order matters: HA-102 follows ai-gateway's contract (AG-2).

---

## E. Decisions needed

| # | Question | Affects | Options |
|---|---|---|---|
| D1 | Is a HotAisle VM "private" for the suite's private-text rule? | ai-gateway `private` attribute | (a) yes: rented single-tenant VM, tailnet only (b) only with extra steps (encrypted disk, no swap) (c) no |
| D2 | How does idle auto-stop delete the VM? | HA-103 | **Decided 2026-11-25: (b) the workstation polls and deletes**, 30 min idle, 4 h cap. HotAisle keys are team-wide (the smallest role that can delete, `operator`, can also create VMs), so no key goes on the VM. |
| D3 | Monthly spend ceiling for HotAisle | HA-106 | amount; what happens at 80% / 100% |

---

## F. Backlog items

### Epic 1: Safe on-demand GPU

#### HA-101 First paid run of the tailnet-only path
Test · **P0** · Approved (2026-11-25), blocked: no HotAisle capacity on 2026-11-25 (nothing created) · S
- **Ready:** workstation on Tailscale; `TS_AUTHKEY` etc. in `~/.config/hotaisle/secrets.sh`; run
  `source ~/.config/hotaisle/secrets.sh && ./deploy_and_run.sh --backend ollama --model llama3.2:3b`.
- **Expected:** API reachable at `http://gpu-hotaisle-<vm>:<port>/v1` from the tailnet only; public IP has only 22 open.
- **Acceptance:** `curl` from outside the tailnet to `<public-ip>:<port>` fails; from the workstation over the tailnet it lists models; the node is removed from the tailnet after `destroy_vm.sh` (ephemeral key). Record cost and timings in `SECURITY-LOG.md` / the timeline.
- **Open:** confirm `sudo -E` keeps the env on HotAisle's image; confirm the default login shell is bash (env file uses `printf %q`).

#### HA-102 Lifecycle contract: up / status / down / cost
Feature · **P1** · Proposed · M · depends on AG-2
- **Expected:** one entry point (`./hotaisle up|status|down|cost [--json]`) the ai-gateway `gpu` CLI calls; `status` reports `{ state, vm, endpoint, model, startedAt, costSoFar }`.
- **Code:** wraps `deploy_and_run.sh` / `destroy_vm.sh`; HotAisle API for listing VMs.

#### HA-103 Idle auto-stop on the VM
Feature · **P0** · Done (60a9fcb), real-VM check pending · M · D2 = (b)
- **Observed:** a forgotten VM bills until someone runs `destroy_vm.sh`.
- **Acceptance:** after `IDLE_MINUTES` (default 30) with no API requests, the VM deletes itself (or is deleted), with a voice line (HA-105).
- **Built:** `idle_stop.sh` (cron on the workstation): idle 30 min, never up in 90 min, or 4 h cap (warned 15 min before); waits out the minimum reservation; only deletes VMs `deploy_and_run.sh` recorded; announces unmanaged ones. Tested against a local mock (every case); not yet on a real VM (do it with HA-101 using `IDLE_MINUTES=5`).
- **Gap:** nothing stops a VM while the workstation is off.

#### HA-104 Keep model weights between VMs
Feature · **P3** · Investigate · M
- **Expected:** cold start in minutes, not a 65–140 GB download each time. Check whether HotAisle offers persistent volumes or snapshots; else a nearby object store.

#### HA-105 deploy-notify voice lines
Feature · **P2** · Proposed · S
- Spoken start / ready / stopped / failed lines through `dalew75/droplet` `bin/deploy-notify` (the standard path), including idle stops.

#### HA-106 Spend log and monthly ceiling
Feature · **P1** · Proposed · S · depends on D3
- Log each VM's start, stop and estimated cost (`~/.hotaisle/spend.jsonl`); refuse `up` past the ceiling.

#### HA-107 Pin the vLLM image
UX · **P2** · Proposed · S
- `:latest` is pulled every deploy, so behavior can change under us. Default to a tested tag; `--vllm-image` overrides.

#### HA-108 Drop the gnome-terminal coupling
UX · **P2** · Proposed · S
- Print the log command (and offer `--logs` to follow in the same terminal) instead of opening a window, so it works headless and from ai-gateway.

#### HA-109 Timeouts: SSH wait and model pull
Bug · **P1** · Done (b343f0f) · S
- See section C.

#### HA-110 Readiness check
Feature · **P1** · Done (f50a72e), real-VM check with HA-101 · S
- After the startup script, poll `/v1/models` over the tailnet until it answers (with a timeout) and only then print "ready".

#### HA-111 shellcheck clean
Chore · **P2** · Done (24c725a, shellcheck 0.9.0) · S
- Run shellcheck on every script and fix warnings (not run on 2026-11-25: not installed).

#### HA-112 VM size choice
Feature · **P3** · Proposed · S
- `--gpus 1|2|4|8` for bigger models / tensor parallel; the vLLM `--tensor-parallel-size` follows it.
