# Security log

Newest first. Every security change or check: date, issue, before → after, what was done, how it was
verified, what's still pending.

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
