# Validation (batch)

Batched validator that compares Kafka payloads to a ClickHouse table and (optionally) emails a summary.

- Python: `validation/validate_batched.py` (or `validate_batched_3.py`)
- Runner: `validation/scripts/validator_batched.sh`
- Venv setup: `validation/install/ensure_venv.sh`
- Optional installer: `validation/setup_local.sh` (called by top-level `bootstrap_server.sh`)

## Repo layout
validation/
README.md
requirements.txt
requirements.lock # optional pinned snapshot
validate_batched.py # or validate_batched_3.py
scripts/
validator_batched.sh # runner that reads envs and calls the Python
install/
ensure_venv.sh # creates/updates venv and installs deps
configs/
.env.example # template for SMTP (no secrets)

makefile


## Prereqs
- Python 3 + `python3-venv` on the host.
- Repo env file (`envs/dev.env`) defines Kafka + ClickHouse variables.
- SMTP creds file at `/etc/sharpe10/validation.env` if you want the summary email.

## Configuration

### A) Non-secret env (in repo): `envs/dev.env`
The runner reads these:

```bash
# Kafka
KAFKA_BROKER_ADDR=10.0.0.210:29092     # or your host:port

# ClickHouse
CH_HOST=server1
CH_PORT=9000
CH_DB=database1
# CH_USER=default                      # optional
# CH_PASSWORD=                         # optional

# Validation behavior
VALIDATION_TOPIC=docker_topic_1
# VALIDATION_CH_TABLE=production_test_table_1      # optional explicit table
VALIDATION_BATCH_SIZE=10000
VALIDATION_COMMIT=0                                 # 1 to commit offsets after run
VALIDATION_USE_LOCK=0                               # 1 to install from requirements.lock
VALIDATION_DOTENV=/etc/sharpe10/validation.env      # where Python loads SMTP vars

# Output filenames (relative to current dir unless absolute paths)
VALIDATION_SUMMARY=summary.json
VALIDATION_DETAILS=details.json
VALIDATION_BAD_ROWS=bad_rows.json
VALIDATION_CH_QUERY_LOG=ch_query_windows.json
If VALIDATION_CH_TABLE isn’t set, the runner tries CONNECT_TOPIC2TABLE="topic=table" if present; otherwise it defaults to production_test_table_1.

B) Secrets (not in repo)
Create /etc/sharpe10/validation.env (see template below) and chmod 600 it.

Install / prepare
Usually called by bootstrap_server.sh:

bash

validation/setup_local.sh --env-file /etc/sharpe10/dev.env
What it does:

Builds/refreshes the virtualenv and installs dependencies.

Installs a convenience wrapper at /usr/local/bin/validate-batched.

Running manually
bash

# Start time may be epoch ms or "YYYY-MM-DD HH:MM:SS" (UTC)
validate-batched "2025-03-01 00:00:00"
# or
validate-batched 1737062400000
Outputs (written to the current working directory unless you set absolute paths):

${VALIDATION_SUMMARY} – summary JSON

${VALIDATION_DETAILS} – details JSON

${VALIDATION_BAD_ROWS} – bad rows JSON

${VALIDATION_CH_QUERY_LOG} – ClickHouse query window log

If SMTP vars are present, the Python sends an email summary; if not, it logs that email is skipped.

Scheduling later (optional)
systemd timer (recommended)
Create /etc/systemd/system/validate-batched.service:

ini

[Unit]
Description=Sharpe10 validation one-shot

[Service]
Type=oneshot
WorkingDirectory=/opt/sharpe10/S10-INFRA/validation
EnvironmentFile=/etc/sharpe10/dev.env
ExecStart=/bin/bash -lc 'ts="$(date -u -d "yesterday 00:00:00" "+%Y-%m-%d %H:%M:%S")"; validate-batched "$ts"'
Create /etc/systemd/system/validate-batched.timer:

ini

[Unit]
Description=Run Sharpe10 validation daily

[Timer]
OnCalendar=*-*-* 23:55:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
Enable:

bash

sudo systemctl daemon-reload
sudo systemctl enable --now validate-batched.timer
sudo systemctl status validate-batched.timer
cron alternative
swift

55 23 * * * /bin/bash -lc 'ts="$(date -u -d "yesterday 00:00:00" "+%Y-%m-%d %H:%M:%S")"; validate-batched "$ts"' >> /var/log/validation.log 2>&1
Troubleshooting
Email not sent → ensure /etc/sharpe10/validation.env exists and has correct values.

CH auth → set CH_USER / CH_PASSWORD (in envs/dev.env or dev.secrets).

DNS/hostnames → ensure the host can resolve server1/server2/server3.

Venv → rebuild via validation/install/ensure_venv.sh
Exact versions: VALIDATION_USE_LOCK=1 validation/install/ensure_venv.sh