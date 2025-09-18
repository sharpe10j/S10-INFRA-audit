SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# -------- Helpers --------
help: ## list available make targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | sed 's/:.*##/: /'

check-env: ## show the env file that will be used (does not modify anything)
	@echo "ROLE=${ROLE:-server2}"
	@echo "Env layering source: envs/dev.env + envs/$${ROLE}/dev.env (if present)"
	@echo "Runtime target: /etc/sharpe10/dev.env"

dev-env: ## create venv & install tools used by scripts
	./validation/install/ensure_venv.sh
	. .venv/bin/activate && pip install -r requirements.txt
	command -v yamllint >/dev/null || pip install yamllint
	command -v shellcheck >/dev/null || true

lint: ## quick repo lint (bash/yaml)
	find . -name '*.sh' -exec bash -n {} +
	[[ -x "$(command -v shellcheck)" ]] && shellcheck -x $$(git ls-files '*.sh') || true
	[[ -x "$(command -v yamllint)"  ]] && yamllint -d '{extends: default, rules: {line-length: {max: 140}}}' . || true

# -------- Render / prepare configs --------
render: ## render all service configs/templates
	./clickhouse/configs/render-clickhouse-configs.sh || true
	./kafka/install/render-kafka.sh || true
	./monitoring/render-monitoring.sh || true

# -------- Local single-node swarm (for testing) --------
swarm-init: ## init local single-node swarm + overlay (no host changes beyond Docker)
	docker swarm init --advertise-addr $$(hostname -I | awk '{print $$1}') 2>/dev/null || true
	NAME=$${SWARM_OVERLAY_NAME:-external-connect-overlay}; \
	docker network create --driver overlay --attachable $$NAME 2>/dev/null || true
	docker network ls --filter driver=overlay

# -------- Deploy stacks --------
deploy-monitor: render ## deploy monitoring stack (Swarm)
	docker stack deploy -c monitoring/configs/monitoring.stack.yml $${MON_STACK_NAME:-s10-monitoring}
	docker stack services $${MON_STACK_NAME:-s10-monitoring}

deploy-kafka: render ## deploy kafka/connect stack (Swarm)
	./kafka/install/deploy-kafka-stack.sh

# -------- Smoke tests (quick health checks) --------
smoke: ## run end-to-end smoke tests (non-destructive)
	./tools/smoke/clickhouse_ping.sh || true
	./tools/smoke/prom_ping.sh || true
	@echo "[smoke] done"

down: ## remove stacks (local only)
	docker stack rm $${MON_STACK_NAME:-s10-monitoring} || true
	docker stack rm s10-kafka || true
