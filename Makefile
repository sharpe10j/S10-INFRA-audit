SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# --- Env vars (add) ---
ENV_NAME ?= dev
ROLE     ?= server1

ENV_FILE       ?= envs/$(ENV_NAME).env
ROLE_ENV_FILE  ?= envs/$(ROLE)/$(ENV_NAME).env
SEEDED_ENV     ?= /etc/sharpe10/dev.env


.PHONY: env
env: ## show which env files will be used
	@echo "ENV_NAME     = $(ENV_NAME)"
	@echo "ROLE         = $(ROLE)"
	@echo "ENV_FILE     = $(ENV_FILE)       ($$(test -f $(ENV_FILE) && echo present || echo missing))"
	@echo "ROLE_ENV     = $(ROLE_ENV_FILE)  ($$(test -f $(ROLE_ENV_FILE) && echo present || echo missing))"
	@echo "SEEDED_ENV   = $(SEEDED_ENV)     ($$(test -f $(SEEDED_ENV) && echo present || echo missing))"

.PHONY: seed
seed: ## build /etc/sharpe10/dev.env from base + role (ROLE=server1|server2|server3)
	@./ops/seed_env.sh $(ROLE)

# -------- Helpers --------
help: ## list available make targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | sed 's/:.*##/: /'

check-env: ## show the env file that will be used (does not modify anything)
	@echo "ROLE=${ROLE:-server2}"
	@echo "Env layering source: envs/dev.env + envs/$${ROLE}/dev.env (if present)"
	@echo "Runtime target: /etc/sharpe10/dev.env"

define LOAD_ENV
if [ -f "$(SEEDED_ENV)" ]; then set -a; . "$(SEEDED_ENV)"; set +a; fi; \
if [ -f "$(ENV_FILE)" ]; then   set -a; . "$(ENV_FILE)"; set +a; fi; \
if [ -f "$(ROLE_ENV_FILE)" ]; then set -a; . "$(ROLE_ENV_FILE)"; set +a; fi
endef

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
.PHONY: smoke
smoke: ## run non-destructive smoke tests (ENV_NAME=dev ROLE=serverX)
	@set -euo pipefail; \
	$(LOAD_ENV); \
	./tools/smoke/clickhouse_ping.sh; \
	./tools/smoke/prom_ping.sh; \
	./tools/smoke/kafka_broker_ping.sh; \
	./tools/smoke/kafka_connect_ping.sh; \
	echo "[smoke] done"

down: ## remove stacks (local only)
	docker stack rm $${MON_STACK_NAME:-s10-monitoring} || true
	docker stack rm s10-kafka || true
