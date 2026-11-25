# hotaisle-deployer timeline

The project's history: where it came from, its milestones, and a dated line for every finished task.
`project-stats hotaisle-deployer` reads this file. Public repo: lines are date-only. Append with the shell
(`cat >> docs/TIMELINE.md <<'EOF'`), never rewrite old lines.

## Origin

- **Conceived:** 2025-12-03 (estimated) · to run gpt-oss:120b privately on a rented AMD GPU for TypingMind
- **First commit:** 2025-12-03 · 77a7eee ("first commit, script works!")
- **First working version:** 2025-12-03 · 77a7eee · uploads a startup script to a HotAisle VM and serves gpt-oss:120b with Ollama
- **First deploy:** not deployed (it rents GPUs on demand; no long-running service)
- **Why it started:** a big open model (120B) behind an OpenAI-style API, without a hosted AI provider seeing the text
- **Came from / replaced:** none. An NVIDIA variant (`with-nvidia`) and a TypingMind variant were tried and parked (`archive/*` tags)

## Milestones

| Date | Milestone | Commit | Notes |
|---|---|---|---|
| 2025-12-03 | first working | 77a7eee | Ollama + gpt-oss:120b on an existing VM |
| 2025-12-03 | v1 | 83f0140 | provisions and destroys VMs through the HotAisle API |
| 2026-03-12 | vLLM | 72fd49b | second backend: any Hugging Face model |
| 2026-04-27 | multi-backend | 3664ca9 | required `--backend`, several models, port flag |
| 2026-11-25 | rename | — | duplicate checkout merged; becomes the HotAisle adapter for ai-gateway |

## Timeline

Format, one line per finished task, newest last:
`- YYYY-MM-DD · <type> · <summary> · <backlog IDs> · <sha>`

- 2025-12-03 · feat · first working script, SSH host key handling, logs in a new terminal (backfilled) · — · 77a7eee
- 2025-12-03 · feat · VM provisioning via the HotAisle API, timings, destroy_vm.sh, last-VM file, docs (backfilled) · — · 7c2442f
- 2025-12-04 · chore · MIT license, .gitignore, REMOTE_USER/REMOTE_PATH, NVIDIA script removed (backfilled) · — · ee14dd4
- 2026-03-12 · feat · vLLM backend, optional model, HF token, extra vLLM args (backfilled) · — · 7823c98
- 2026-03-13 · refactor · startup-vllm.sh serve command (backfilled) · — · c8190fb
- 2026-04-27 · feat · required --backend, multi-model Ollama and vLLM, port flag (unpushed until 2026-11-25) (backfilled) · — · 3664ca9
- 2026-11-25 · chore · merged the duplicate ~/dev/fresh-github checkout (vLLM flags, Gemma 4 hotfix), archived 5 old branches as tags, removed startup-amd.sh · — · e1551e9
- 2026-11-25 · security · model API on the tailnet only (secure-net.sh, TS_AUTHKEY required), secrets via env file · HA-101 · 1535453
- 2026-11-25 · docs · standard setup: AGENTS.md, README, BACKLOG (HA-101..112, proposed sprint), TIMELINE, SECURITY-LOG; role: HotAisle adapter for ai-gateway · HA-101 · 55f4caa
- 2026-11-25 · fix · HA-101 attempt: HotAisle had no capacity (nothing created); capacity check before create, readable API errors · HA-101 · pending
- 2026-11-25 · test · HA-101 retried on DigitalOcean (tailnet mode added there): RTX 6000 Ada create removed by DO after 7 s (no capacity); nothing ran · HA-101 · pending
- 2026-11-25 · test · tailnet-only bind verified on a DigitalOcean H100 (ams3, ~7 min): API on tailnet only, public port refused, droplet and node gone after destroy; HotAisle run still pending · HA-101 · see SECURITY-LOG
- 2026-11-25 · feat · HA-103 idle auto-stop from the workstation (cron, 30 min idle / 4 h cap); D2 = (b) decided · HA-103 D2 · 60a9fcb
- 2026-11-25 · fix · HA-109 SSH and remote-setup timeouts, failed setup reported · HA-109 · b343f0f
- 2026-11-25 · chore · HA-111 shellcheck clean (0.9.0) · HA-111 · 24c725a
- 2026-11-25 · feat · HA-110 readiness check: wait for /v1/models over the tailnet before "ready" · HA-110 · f50a72e
