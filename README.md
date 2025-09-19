# s10-infra
Supporting Infrastructure
## Quick links
- [docs/ONBOARDING.md](docs/ONBOARDING.md)
- [docs/OVERVIEW.md](docs/OVERVIEW.md)
- [AGENTS.md](AGENTS.md)

## Plan mode (dry-run bootstrap)

Use plan mode to produce a transcript of what `bootstrap_server.sh` would
execute on each role without touching the host. The helper script prepares
Docker shims, selects the matching `envs/<role>/dev.env`, and stores the
output under `plan-logs/` for later review.

```bash
# ROLE can be server1|server2|server3; optionally pass KEEPER_ID for server1
make plan ROLE=server2

# Direct invocation if you prefer not to use make
./tools/plan_server.sh --role server3
```

When run on Codex (or any system without Docker), the plan still succeeds and
shows which Swarm/Kafka steps would have been called on a real host.
