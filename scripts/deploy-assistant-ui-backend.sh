#!/usr/bin/env bash
# Pulls alexvirt1/assistant-ui-langgraph-fastapi and (re)installs backend/
# as assistant-ui-backend.service.
#
# Mirrors the exact working setup: Poetry in-project venv (backend/.venv,
# per poetry.toml) pinned to Python 3.12, uvicorn app served via
# `python -m app.server` on :8000, DATABASE_URL injected through a systemd
# drop-in so the secret never has to live in the repo or in this script.
#
# Requires git, poetry, and python3.12 on PATH - run scripts/install-prereqs.sh
# first on a host that doesn't have them yet.
#
# Idempotent: safe to re-run to pick up new commits and restart the service.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_non_root

REPO_URL="${ASSISTANT_UI_REPO_URL:-https://github.com/alexvirt1/assistant-ui-langgraph-fastapi.git}"
REPO_DIR="${ASSISTANT_UI_DIR:-/opt/ai-agent-lab/assistant-ui-langgraph-fastapi}"
BACKEND_DIR="$REPO_DIR/backend"
SERVICE_NAME="assistant-ui-backend"
SERVICE_USER="${SERVICE_USER:-ubuntu}"

ensure_local_bin_on_path

require_cmd git
require_cmd poetry
require_cmd python3.12

log "== assistant-ui-backend: pull repo =="
clone_or_update "$REPO_URL" "$REPO_DIR"

check_postgres_running || warn "continuing anyway, but the backend will fail to start without Postgres reachable"

log "== assistant-ui-backend: poetry install =="
# backend/poetry.toml sets virtualenvs.in-project=true, so this creates
# backend/.venv automatically. Pin the interpreter to 3.12 explicitly -
# otherwise Poetry picks up whatever 'python3' happens to default to on
# this host, which install-prereqs.sh does not change system-wide.
(cd "$BACKEND_DIR" && poetry env use python3.12 && poetry install)

log "== assistant-ui-backend: ensure .env (non-secret config) =="
ensure_env_file "$BACKEND_DIR/.env" "$(cat <<'EOF'
OLLAMA_MODEL=qwen3:8b
OLLAMA_BASE_URL=http://192.168.87.160:11434
OLLAMA_NUM_CTX=8192
EOF
)"

log "== assistant-ui-backend: install systemd unit =="
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=assistant-ui LangGraph FastAPI backend
After=network.target postgresql.service

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${BACKEND_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=${BACKEND_DIR}/.venv/bin/python -m app.server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log "== assistant-ui-backend: ensure DATABASE_URL drop-in =="
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
DROPIN_FILE="$DROPIN_DIR/override.conf"
if sudo test -f "$DROPIN_FILE"; then
  log "$DROPIN_FILE already exists, leaving it untouched"
else
  prompt_secret ASSISTANT_UI_DATABASE_URL \
    "Enter DATABASE_URL for assistant-ui-backend (postgresql://user:pass@127.0.0.1:5432/assistant_ui)"
  if [ -z "${ASSISTANT_UI_DATABASE_URL:-}" ]; then
    warn "No DATABASE_URL provided - skipping drop-in. Backend will run WITHOUT Postgres persistence until you create:"
    warn "  $DROPIN_FILE  with: [Service]\\nEnvironment=DATABASE_URL=postgresql://..."
  else
    sudo mkdir -p "$DROPIN_DIR"
    sudo tee "$DROPIN_FILE" >/dev/null <<EOF
[Service]
Environment=DATABASE_URL=${ASSISTANT_UI_DATABASE_URL}
EOF
  fi
fi

log "== assistant-ui-backend: enable + restart =="
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

sleep 2
sudo systemctl status "$SERVICE_NAME" --no-pager || true

log "== assistant-ui-backend: health check =="
if curl -fsS "http://127.0.0.1:8000/openapi.json" >/dev/null 2>&1; then
  log "OK: http://127.0.0.1:8000/openapi.json is responding"
else
  warn "Health check failed - inspect: journalctl -u $SERVICE_NAME -n 80 --no-pager"
fi
