#!/usr/bin/env bash
# Runs both deploy scripts in order (alexvirt1/assistant-ui-langgraph-fastapi):
#   1. assistant-ui-backend.service
#   2. assistant-ui-frontend.service
#
# PostgreSQL is provisioned first via install-postgres.sh (idempotent: it
# installs the package, starts the service, and creates the role/database
# pair the backend expects only if it doesn't already exist). Set
# SKIP_POSTGRES_INSTALL=1 to skip this and just verify it's already running
# (e.g. Postgres is managed elsewhere).
#
# Ollama is NOT installed here - it commonly runs on a separate GPU VM, so
# installing it is out of scope for a script meant to run on the app host.
# Use scripts/install-ollama.sh directly on whichever host should serve it
# (this one or another). This script only checks it's reachable.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib.sh"

log "== preflight: PostgreSQL =="
if [ "${SKIP_POSTGRES_INSTALL:-0}" = "1" ]; then
  check_postgres_running || die "PostgreSQL is not running locally. Start it or unset SKIP_POSTGRES_INSTALL to install it."
else
  "$SCRIPT_DIR/install-postgres.sh"
fi

log "== preflight: Ollama =="
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://192.168.87.160:11434}"
if curl -fsS "${OLLAMA_BASE_URL}/api/tags" >/dev/null 2>&1; then
  log "Ollama reachable at $OLLAMA_BASE_URL"
else
  warn "Ollama not reachable at $OLLAMA_BASE_URL - chats will fail until it is up."
  warn "Run scripts/install-ollama.sh on the host that should serve it (set OLLAMA_BASE_URL if it's not 192.168.87.160)."
fi

"$SCRIPT_DIR/deploy-assistant-ui-backend.sh"
"$SCRIPT_DIR/deploy-assistant-ui-frontend.sh"

log "== final validation =="
curl -fsS http://127.0.0.1:8000/openapi.json >/dev/null && echo "assistant-ui-backend :8000 OK" || warn "assistant-ui-backend :8000 not responding"
curl -fsSI http://127.0.0.1:3000/ >/dev/null && echo "assistant-ui-frontend :3000 OK" || warn "assistant-ui-frontend :3000 not responding"

log "Done. Manual check: open http://<server-ip>:3000 and ask 'What time is it?' - confirm the current_time tool fires:"
log "  journalctl -u assistant-ui-backend -n 50 --no-pager"
