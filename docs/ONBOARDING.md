# S10-INFRA onboarding

Welcome! This repo bootstraps and operates the three-node Sharpe10 analytics stack. It holds the host bootstrap scripts, Swarm stack manifests, and smoke checks you will use to keep ClickHouse, Kafka, and monitoring healthy. This guide highlights how things fit together and where to start improving them.

## What this repo delivers
- **server1 – ClickHouse primary**: Bare-metal ClickHouse + Keeper plus host-only monitoring agents.
- **server2 – Swarm manager**: Docker Swarm manager that runs monitoring, Kafka Connect, and replicated ClickHouse services.
- **server3 – Swarm worker**: Worker node that hosts Kafka brokers/ZooKeeper and complements the Swarm deployment.

The top-level `bootstrap_server*.sh` wrappers install prerequisites, seed environment files, and dispatch to the right role-specific installer.

## Repository map (1–2 lines each)
- `Makefile` – entry point for env inspection, rendering configs, deployment, smoke checks.
- `bootstrap_server*.sh` – turnkey host provisioning for each role; call into `ops/` utilities.
- `clickhouse/` – ClickHouse configs, render scripts, service installers, and systemd assets.
- `kafka/` – Kafka/ZooKeeper/Connect templates and deployment helpers for Swarm.
- `monitoring/` – Prometheus, Alertmanager, Grafana stacks plus host/node exporter setup.
- `envs/` – layered environment defaults (`dev.env`) and per-role overrides consumed by seeds.
- `ops/` – foundational host setup (Docker, Python, directories, env seeding, Swarm init).
- `templates/` – example config templates ready to copy or extend.
- `tools/smoke/` – bash probes used by `make smoke` (ClickHouse ping, Prometheus ping, Kafka ping).
- `tools/shell/` – adhoc shell helpers (e.g., monitoring dashboards fetches).
- `validation/` – Python tooling/venv bootstrap and shared validation scripts.
- `docs/` – reference docs, networking samples, and (now) this onboarding guide.

## Key concepts and improvement pointers
- **Environment layering** drives everything. Keep `envs/dev.env` minimal and push host-specific overrides into `envs/<role>/dev.env`. Missing values lead to runtime surprises; lint them.
- **Rendered configs are artifacts.** Anything under `*/configs/` is generated; regenerate with `make render` whenever templates change.
- **Bootstrap scripts double as documentation.** Read them end-to-end before running; they show sequencing and guardrails.
- **Improvements to tackle next**
  - Add automated validation for env files (shellcheck/yamllint already optional in `make lint`).
  - Expand smoke tests to assert data paths (e.g., ClickHouse query, Kafka topic round-trip).
  - Publish architecture diagrams under `docs/diagrams/` and add runbooks for common ops.

## Environment layering & configuration commands
`make env` echoes which env files will be loaded and whether they exist. Runtime layering order:
1. `/etc/sharpe10/dev.env` (generated via `make seed ROLE=...` or `./ops/seed_env.sh <role>`)
2. `envs/dev.env` (global defaults)
3. `envs/<role>/dev.env` (role-specific overrides)

`make seed ROLE=server2` writes `/etc/sharpe10/dev.env` by concatenating the base + role overrides with helpful comments. Run it on every host, and rerun after editing env files.

## Make targets you will use most
| Target | Purpose |
| --- | --- |
| `make help` | Discover documented targets. |
| `make dev-env` | Create `.venv` and install lint/scripting dependencies from `validation/`. |
| `make render` | Regenerate ClickHouse, Kafka, and monitoring configs via their render scripts. |
| `make deploy-monitor` / `make deploy-kafka` | Deploy Docker Swarm stacks (manager node only). |
| `make smoke ROLE=serverX SMOKE_MODE=mock|live` | Run role-specific health checks (mock skips network). |
| `make swarm-init` | (Server2/local) Initialize Swarm and overlay network. |
| `make down` | Remove Swarm stacks locally. |

## Quickstart
1. **Clone repo & inspect targets**
   ```bash
   make help
   ```
2. **Prep local tooling**
   ```bash
   make dev-env
   ```
3. **Seed environment on the host** (choose the role you are configuring)
   ```bash
   sudo make seed ROLE=server2
   make env ROLE=server2
   ```
4. **For Swarm hosts** (server2 locally, server3 joins via docker CLI)
   ```bash
   sudo make swarm-init        # run once on server2
   docker swarm join --token <WORKER_TOKEN> <MANAGER_IP>:2377   # server3
   ```
5. **Render configs before deploying**
   ```bash
   make render
   ```
6. **Deploy stacks from server2** (manager)
   ```bash
   make deploy-monitor
   make deploy-kafka
   ```
7. **Smoke-test**
   ```bash
   make smoke ROLE=server2 SMOKE_MODE=live
   ```

Use `SMOKE_MODE=mock` locally/CI to skip live network access and just validate env wiring.

## Deploying ClickHouse on server1
- Bootstrap with `sudo ./bootstrap_server.sh --role server1 --keeper-id <id>` after seeding the env.
- The script ensures log directories, installs node exporter, and invokes `clickhouse/setup_local.sh`.
- Re-run `clickhouse/configs/render-clickhouse-configs.sh` then restart services whenever configs change.

## CI & automation
The workflow `.github/workflows/repo-health.yml` runs on every push and PR. It iterates over `server1`, `server2`, and `server3`, executes `make help`, and then runs `make smoke` in `SMOKE_MODE=mock`. This verifies env files parse and required variables exist without hitting real infrastructure. Keep smoke scripts idempotent and mock-friendly so CI remains fast and reliable.

## Smoke testing guidance (live mode)
- **server1**: Run `make smoke ROLE=server1 SMOKE_MODE=live` after ClickHouse upgrades, keeper changes, or restoring from backup. Confirms SQL port responds.
- **server2**: Run after deploying monitoring stack changes, Kafka Connect updates, or Swarm manager upgrades. Ensures Prometheus and Connect endpoints respond.
- **server3**: Run after Kafka/ZK config updates, broker restarts, or storage maintenance. Validates broker port is reachable.
- **Always run live smoke** post-deploy, before handing off on-call, and after any host-level change (kernel/docker updates).

## Tips for working in this repo
- Prefer `make` targets over running scripts directly; they manage env layering for you.
- Keep `/etc/sharpe10` under source control on the host (e.g., with etckeeper) so env drift is visible.
- Render configs in git, commit templates only. Generated files under `*/configs/` should be gitignored but inspected before deployments.
- Use `make lint` before committing script changes; it surfaces shell/yaml issues early.

## Next steps once you are comfortable
1. Harden secrets management by templating `dev.secrets` examples.
2. Automate nightly smoke runs via cron on server2 using `make smoke` in live mode.
3. Flesh out `docs/runbooks/` with failure scenarios (ClickHouse lag, Kafka ISR loss, etc.).

Welcome aboard—reach out in `#infra-ops` if anything here is unclear or needs deeper examples.
