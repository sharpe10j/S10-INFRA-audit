# AGENTS.md

## Goals
- Bring up a single-node test environment.
- Verify bootstrap scripts work on a fresh host (single-node test)
- Validate Docker/Swarm stacks render and deploy
- Run smoke tests (Kafka → ClickHouse, monitoring up)

## Env & prerequisites
- OS: Ubuntu 24.04 with Docker Engine installed
- Run: `make dev-env` to set up Python venv and tools
- Create runtime env: `./ops/seed_env.sh server2` (or `server3` / `server1`)
- For local single-node tests, run: `make swarm-init`

## Prep (make scripts executable)
> Some `.sh` files may not have the executable bit set.
```bash
git ls-files -z '*.sh' | xargs -0 -I{} git update-index --chmod=+x "{}"
```