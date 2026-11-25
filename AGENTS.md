# AGENTS.md — hotaisle-deployer

Bash tooling that rents an AMD MI300X VM on HotAisle and serves models with Ollama or vLLM. Read `README.md`
for usage. No build system, package manager or tests; check changes with `bash -n` (and `shellcheck` when
available).

**Role in the suite:** the HotAisle provider adapter for `../ai-gateway` (registry of AI providers with
attributes such as local / private / cost, plus the GPU start/stop front door). `../digitalocean` is the
DigitalOcean adapter. Lifecycle contract, voice announcements, idle auto-stop and spend limits are planned
in ai-gateway (`AG-2`) and here (`HA-102`…`HA-106`); keep provider-specific knowledge here and generic
logic there.

## Scripts

| Script | Runs where |
|---|---|
| `deploy_and_run.sh` (`--backend ollama\|vllm`, `--public`, vLLM flags) | local |
| `destroy_vm.sh [vm-name]` (default `~/.hotaisle_last_vm`) | local |
| `secure-net.sh` | **remote VM**, uploaded and run with sudo before the startup script |
| `startup-ollama.sh` / `startup-vllm.sh` | **remote VM**, uploaded to `/home/<user>/start.sh` |

Remote scripts are never run locally. Their env arrives in `~/.deploy.env` (mode 600, sourced then deleted).

## Rules

- **Money:** never provision, deploy to, or destroy a VM without the owner's go-ahead each time, and state
  the hourly price (looked up, dated) first. Real runs: `HA-101` lists what to verify.
- **Network:** tailnet only by default (`TS_AUTHKEY` required, ports bound to the tailnet IP; Docker bypasses
  ufw, so the bind address is the real protection). Don't weaken this; `--public` stays opt-in with a warning.
- **Secrets:** never on a command line or in the repo. This repo is **public**.
- **Git:** commit finished changes and push to `origin` (owner, 2026-11-25). Public repo: `docs/TIMELINE.md`
  lines are date-only.
- **Prices and speeds:** don't quote from memory; look them up and date them.
- **Security log:** every security change or check goes in `SECURITY-LOG.md` (newest first), same session.

## Standard-kit decisions (2026-11-25)

- **Deploy setup:** not applicable. "Deploying" here means renting a GPU, not shipping a site, so the droplet
  `site-deploy` / slots kit doesn't fit. The equivalent (`up / status / down / cost`, deploy-notify voice
  lines, spend log) is backlog work: `HA-102`, `HA-105`, `HA-106`, `AG-2`.
- **Preview / go live / what's new:** not applicable (no UI).
- **Sensitive data on screen:** none shown. Prompts pass through the VM; HotAisle (the host) could in
  principle read VM memory and disk. Treat it as "private enough" only by the owner's call (`D1` in the
  backlog); ai-gateway records it as the entry's `private` attribute.

## Docs

- `docs/BACKLOG.md`: planned work, prefix `HA-`. Nothing in it is approved until the owner says so.
- `docs/TIMELINE.md`: history; append with the shell, date only.
- `SECURITY-LOG.md`: security changes and checks.

## State files

- `~/.hotaisle_last_vm`: last provisioned VM name (written by deploy, read and cleared by destroy).
- `~/.ssh/known_hosts`: old entries for the target IP are removed on deploy.
