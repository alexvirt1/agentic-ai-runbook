#!/usr/bin/env bash
# Pulls alexvirt1/ai-assistant-ui-fastapi and (re)installs backend/
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

REPO_URL="${ASSISTANT_UI_REPO_URL:-https://github.com/alexvirt1/ai-assistant-ui-fastapi.git}"
REPO_DIR="${ASSISTANT_UI_DIR:-/opt/ai-agent-lab/ai-assistant-ui-fastapi}"
# Which branch to deploy. deploy-all.sh exports this from its --branch flag;
# set it directly to run this script standalone against e.g. dev.
BRANCH="${ASSISTANT_UI_BRANCH:-main}"
BACKEND_DIR="$REPO_DIR/backend"
SERVICE_NAME="assistant-ui-backend"
SERVICE_USER="${SERVICE_USER:-ubuntu}"

ensure_local_bin_on_path

require_cmd git
require_cmd poetry
require_cmd python3.12

log "== assistant-ui-backend: pull repo (branch: $BRANCH) =="
clone_or_update "$REPO_URL" "$REPO_DIR" "$BRANCH"

check_postgres_running || warn "continuing anyway, but the backend will fail to start without Postgres reachable"

log "== assistant-ui-backend: poetry install =="
# backend/poetry.toml sets virtualenvs.in-project=true, so this creates
# backend/.venv automatically. Pin the interpreter to 3.12 explicitly -
# otherwise Poetry picks up whatever 'python3' happens to default to on
# this host, which install-prereqs.sh does not change system-wide.
#
# --no-root: backend/pyproject.toml declares readme = "README.md", but
# that file only exists at the repo root, not inside backend/, so
# installing "backend" itself as a package fails with "Readme path ...
# does not exist" (upstream packaging bug, not this host). We don't need
# it installed anyway - the systemd unit runs `python -m app.server` from
# WorkingDirectory=backend/, and app/ has its own __init__.py, so Python
# resolves it from the working directory without a package install. This
# flag just skips packaging the project; dependencies still install
# normally.
(cd "$BACKEND_DIR" && poetry env use python3.12 && poetry install --no-root)

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
  # Drop-ins written before the %-escaping fix silently lose their
  # DATABASE_URL (see systemd_escape_percent in lib.sh). We don't rewrite the
  # file - it may have been hand-tuned - but an unescaped '%' means the
  # backend is running without Postgres, so say so loudly.
  EXISTING_URL="$(sudo sed -n 's/^Environment=DATABASE_URL=//p' "$DROPIN_FILE")"
  # Strip the valid '%%' escapes first; any '%' still standing is the bad kind.
  if [ -n "$EXISTING_URL" ] && [[ "${EXISTING_URL//%%/}" == *%* ]]; then
    warn "$DROPIN_FILE contains an unescaped '%' in DATABASE_URL - systemd will discard that line and the backend will start WITHOUT Postgres."
    warn "Fix it by doubling each '%' in that file, or delete it and re-run this script:"
    warn "  sudo rm $DROPIN_FILE && $SCRIPT_DIR/deploy-assistant-ui-backend.sh"
  fi
else
  # install-postgres.sh already knew the password when it created the role, so
  # reuse what it recorded rather than prompting for the same secret twice.
  if [ -z "${ASSISTANT_UI_DATABASE_URL:-}" ] && ASSISTANT_UI_DATABASE_URL="$(load_saved_database_url)"; then
    log "Reusing the DATABASE_URL recorded by install-postgres.sh ($ASSISTANT_UI_DB_ENV_FILE)"
  else
    prompt_secret ASSISTANT_UI_DATABASE_URL \
      "Enter DATABASE_URL for assistant-ui-backend (postgresql://user:pass@127.0.0.1:5432/assistant_ui)"
  fi
  if [ -z "${ASSISTANT_UI_DATABASE_URL:-}" ]; then
    warn "No DATABASE_URL provided - skipping drop-in. Backend will run WITHOUT Postgres persistence until you create:"
    warn "  $DROPIN_FILE  with: [Service]\\nEnvironment=DATABASE_URL=postgresql://..."
  else
    sudo install -d -m 0755 -o root -g root "$DROPIN_DIR"
    # 0600 before writing: the drop-in embeds the DB password, and systemd
    # reads unit files as root so it does not need to be world-readable.
    sudo install -m 0600 -o root -g root /dev/null "$DROPIN_FILE"
    sudo tee "$DROPIN_FILE" >/dev/null <<EOF
[Service]
Environment=DATABASE_URL=$(systemd_escape_percent "$ASSISTANT_UI_DATABASE_URL")
EOF
  fi
fi

log "== assistant-ui-backend: enable + restart =="
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

sleep 2
sudo systemctl status "$SERVICE_NAME" --no-pager || true

log "== assistant-ui-backend: verify DATABASE_URL reached the service =="
# The health check below passes either way: the backend starts fine without
# DATABASE_URL, it just runs with no Postgres persistence. So confirm systemd
# actually kept the variable rather than discarding the line. grep -q, never
# echo - the resolved value contains the DB password.
if sudo test -f "$DROPIN_FILE"; then
  if systemctl show -p Environment "$SERVICE_NAME" | grep -q 'DATABASE_URL='; then
    log "OK: DATABASE_URL is present in the unit environment"
  else
    warn "DATABASE_URL is set in $DROPIN_FILE but did NOT reach the service - systemd discarded the line (usually an unescaped '%'; see journalctl for 'Failed to resolve specifiers')."
    warn "The backend is running WITHOUT Postgres persistence. Inspect: sudo systemd-analyze verify /etc/systemd/system/${SERVICE_NAME}.service"
  fi
fi

log "== assistant-ui-backend: health check =="
if curl -fsS "http://127.0.0.1:8000/openapi.json" >/dev/null 2>&1; then
  log "OK: http://127.0.0.1:8000/openapi.json is responding"
else
  warn "Health check failed - inspect: journalctl -u $SERVICE_NAME -n 80 --no-pager"
fi
