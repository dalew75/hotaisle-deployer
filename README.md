# hotaisle-deployer

Bash scripts that rent an AMD MI300X GPU VM on [HotAisle](https://hotaisle.xyz), serve one or more
models on it with **Ollama** or **vLLM** (OpenAI-compatible API), and delete the VM when you're done.

It is the HotAisle provider adapter for `ai-gateway` (the hub that lists AI providers with their
attributes: local, private, cost, capabilities). It works fine on its own too.

> **Costs money.** A 1× MI300X VM is billed while it exists (about $2–3/hr as of 2026-11; check
> HotAisle's pricing). Always run `./destroy_vm.sh` when you're done.

## Scripts

| Script | Runs where | What it does |
|---|---|---|
| `deploy_and_run.sh` | your machine | Provisions a VM (unless you pass an IP), uploads the scripts below, runs them, prints the endpoint and timings |
| `destroy_vm.sh` | your machine | Deletes a VM by name (default: the last one, from `~/.hotaisle_last_vm`) |
| `secure-net.sh` | the VM | Joins the VM to your tailnet and turns on ufw (skipped with `--public`) |
| `startup-ollama.sh` | the VM | Docker + `ollama/ollama:rocm`, pulls the model(s), one port |
| `startup-vllm.sh` | the VM | Docker + `vllm/vllm-openai-rocm`, one container per model on ports PORT, PORT+1, … |
| `Dockerfile.vllm-rocm-gemma4-hotfix` | a Docker host | vLLM ROCm image with a one-line fix for Gemma 4 checkpoints (`embed_tokens.biases`) |

## Quick start

```bash
export HOTAISLE_TEAM_NAME="your-team"
export HOTAISLE_TOKEN="your-api-token"
export TS_AUTHKEY="tskey-auth-..."   # ephemeral, pre-authorized Tailscale key (e.g. tag:gpu)

# Ollama, default model gpt-oss:120b
./deploy_and_run.sh --backend ollama

# vLLM, a Hugging Face model
./deploy_and_run.sh --backend vllm --model Qwen/Qwen2.5-72B-Instruct

# Deploy to a VM you already have
./deploy_and_run.sh --backend ollama --model llama3.2:3b <GPU_IP>

# Done: delete the VM (stops billing)
./destroy_vm.sh
```

At the end it prints the endpoint, e.g. `http://gpu-hotaisle-<vm>:8000/v1`. Any non-empty API key works.

## Network: tailnet only by default

The model API has no authentication of its own. So by default the VM joins your
[Tailscale](https://tailscale.com) tailnet and the API ports are published **on the tailnet IP only**;
the public IP only has SSH open. `deploy_and_run.sh` refuses to start without `TS_AUTHKEY`.

- Use an **ephemeral** auth key, so the machine leaves the tailnet when the VM is deleted, and a tag
  (e.g. `tag:gpu`) so your tailnet ACL can decide which of your machines may reach it.
- `TS_HOSTNAME` sets the machine name (default `gpu-hotaisle-<vm-name>`).
- `--public` skips all of this and publishes on every interface with no auth. Anyone who finds the IP
  can use the GPU and read prompts. Only for throwaway tests.
- Secrets (`TS_AUTHKEY`, `--hf-token`) are sent in a mode-600 env file that the VM deletes right after
  reading it. They never appear on the SSH command line.

## Options (`deploy_and_run.sh`)

| Option | Meaning |
|---|---|
| `--backend ollama\|vllm` | Required |
| `--model a,b` | Ollama tags or Hugging Face IDs, comma-separated. Defaults: `gpt-oss:120b` / `Qwen/Qwen2.5-VL-72B-Instruct` |
| `--port N` | Starting port (default 8000) |
| `--public` | No Tailscale; publish on the public IP (no auth) |
| `--hf-token T` | Hugging Face token for gated models (vLLM) |
| `--vllm-max-model-len N` | Context length (default 131072) |
| `--vllm-trust-remote-code` / `--no-vllm-trust-remote-code` | Default on |
| `--vllm-no-qwen-tool-stack` | Drop the Qwen3 reasoning/tool parser flags (for non-Qwen models) |
| `--vllm-disable-reasoning` | `enable_thinking: false` in the chat template |
| `--vllm-image ref` | Docker image (default `vllm/vllm-openai-rocm:latest`, pulled every deploy) |
| `--vllm-extra-args "…"` | Passed through last |

Environment: `HOTAISLE_TEAM_NAME`, `HOTAISLE_TOKEN` (provisioning), `TS_AUTHKEY`, `TS_HOSTNAME`,
`REMOTE_USER` (default `hotaisle`), `HOTAISLE_USER_DATA_URL` (cloud-init).

## VM spec requested

1× AMD MI300X (192 GB HBM3), 13 Xeon Platinum 8470 cores, 240 GB RAM, 12 TB disk (`deploy_and_run.sh`).

## Notes

- Model downloads are the slow part: `gpt-oss:120b` (~65 GB) or a 70B model in full precision (~140 GB)
  can take 10–60 minutes. The spinner only says the SSH session is still open.
- With several Ollama models, they share one port; with vLLM, each model gets its own container and port.
- AMD/ROCm only. Some new models need a newer or patched vLLM image (see the Gemma 4 Dockerfile).
- Logs: `ssh hotaisle@<IP> 'docker logs -f ollama'` (or `vllm`, `vllm-<port>`). On GNOME a terminal
  opens with them automatically.

## Docs

- `AGENTS.md`: rules for coding agents working here.
- `docs/BACKLOG.md`: planned work. `docs/TIMELINE.md`: history. `SECURITY-LOG.md`: security changes.

## License

MIT, see [LICENSE](LICENSE).
