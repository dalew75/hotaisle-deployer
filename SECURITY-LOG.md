# Security log

Newest first. Every security change or check: date, issue, before → after, what was done, how it was
verified, what's still pending.

## 2026-11-25 — Tailnet-only bind verified on a real GPU (DigitalOcean H100, same pattern)

- **Run:** owner approved one DigitalOcean `gpu-h100x1-80gb` test in ams3 ($4.41/hr, `doctl compute size
  list`, 2026-11-25) after the capacity watcher reported ams3. `../digitalocean` `deploy_gpu.sh` +
  `deploy_model.sh` with `TS_AUTHKEY` (ephemeral), vLLM `v0.30.0`, `Qwen/Qwen2.5-0.5B-Instruct`. Wrapper
  destroyed the droplet on exit. Created 07:53, destroyed 08:01 (about 7 min, about $0.55).
- **Verified:** on the droplet, `ss -ltnp` showed port 8000 bound only to its tailnet IP (`docker-proxy`);
  from the workstation, `/v1/models` and a chat completion answered over the tailnet; `curl` to the public
  IP on 8000 was refused. After destroy: DELETE returned 204, `doctl compute droplet list` no longer shows
  it, and `tailscale status` has no `gpu-do-*` node.
- **Scope:** proves the "bind to the tailnet IP, Docker can't bypass it" approach on real hardware. It does
  not run this repo's scripts (`secure-net.sh`, ufw, `startup-*.sh`, the env-file handoff, Ollama).
- **Pending:** HA-101 on HotAisle itself once it has capacity.

## 2026-11-25 — HA-101 attempt: no capacity; second operator on the HotAisle team

- **Run:** owner approved one 1× MI300X test ($2.99/hr, hotaisle.xyz/pricing, 2026-11-25). The create request
  failed within 2 s: `virtual_machines/available/` returned `null` (no capacity), and the POST reply was not
  JSON, so the script stopped at `jq`. Checked `GET virtual_machines/` before and after: `[]`. Nothing was
  created or billed. The old `enc1-gpuvm014` from 2026-04 no longer exists.
- **Fix:** `deploy_and_run.sh` now checks availability before creating anything (exit 2, "nothing created or
  billed"), prints HotAisle's message when a reply isn't JSON, and only writes `~/.hotaisle_last_vm` once a VM
  name comes back. Verified: rerun stops at the capacity check (exit 2); non-JSON is still caught.
- **Observed:** the HotAisle team has a second member added 2026-01-25 with the `operator` role (can create
  and delete VMs on the team's bill). Flagged to the owner to confirm or remove in the HotAisle console.
- **Workstation:** Tailscale installed and joined for the tailnet-only path. Secrets in
  `~/.config/hotaisle/secrets.sh` (mode 600, outside the repo).
- **Pending:** HA-101 itself (tailnet-only check on a real VM) once HotAisle has capacity.

## 2026-11-25 — Model API was public with no auth; token on the SSH command line

- **Issue:** `startup-ollama.sh` / `startup-vllm.sh` published the API (`-p PORT:…`) on every interface of
  the VM's public IP. Ollama and vLLM have no auth, so anyone who found the IP could use the GPU (on our
  bill) and read prompts and answers. Also, `--hf-token` was put in the remote SSH command line, so it was
  visible in the VM's process list and shell history.
- **Before → after:** public `0.0.0.0` bind → bind to the Tailscale IP only (`TAILNET_ONLY=1`).
  `deploy_and_run.sh` now refuses to run without `TS_AUTHKEY` unless `--public` is given. New
  `secure-net.sh` joins the tailnet and enables ufw (deny incoming except SSH and `tailscale0`; a second
  layer only, since Docker-published ports bypass ufw). Secrets go in a mode-600 env file that the VM
  sources and deletes. Commit `1535453`.
- **Verified:** `bash -n` on all scripts; `deploy_and_run.sh --backend ollama` without `TS_AUTHKEY` exits 1
  before any API call; env-file quoting round-trips values containing quotes, spaces and `$`.
- **Pending:** not yet run on a real VM (needs a paid run: `HA-101`). `shellcheck` not run (not installed
  here). Old VMs created before this change, if any still exist, are still public: delete them.
