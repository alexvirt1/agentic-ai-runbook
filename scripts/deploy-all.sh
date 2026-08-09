#!/usr/bin/env bash
# Runs both deploy scripts in order (alexvirt1/ai-assistant-ui-fastapi):
#   1. assistant-ui-backend.service
#   2. assistant-ui-frontend.service
#
# Deploys the 'main' branch by default. Pass -b/--branch (or a bare branch
# name) to deploy something else - e.g. `./deploy-all.sh dev` to test the
# dev branch before it's merged. Both services always come from the same
# branch, and both are re-installed/rebuilt from it, so switching back is
# just another run with the other branch name.
#
# OS-level tooling (git, build tools, Python 3.12 + Poetry, Node 20 +
# Corepack) is provisioned first via install-prereqs.sh - safe to re-run,
# and safe on a clean VM that has none of it yet. Set
# SKIP_PREREQS_INSTALL=1 to skip this (e.g. it's already been run once).
#
# PostgreSQL is provisioned next via install-postgres.sh (idempotent: it
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

usage() {
  cat <<'EOF'
Usage: deploy-all.sh [-b|--branch <branch>] [<branch>]

Options:
  -b, --branch <branch>   Branch of alexvirt1/ai-assistant-ui-fastapi to
                          deploy (default: main, or $ASSISTANT_UI_BRANCH).
  -h, --help              Show this help and exit.

Examples:
  ./deploy-all.sh                  # deploy main
  ./deploy-all.sh dev              # deploy the dev branch
  ./deploy-all.sh --branch feat/x  # deploy any other branch

Environment:
  ASSISTANT_UI_BRANCH      Same as --branch (the flag wins if both are set).
  SKIP_PREREQS_INSTALL=1   Skip the OS prerequisites step.
  SKIP_POSTGRES_INSTALL=1  Skip installing Postgres (just verify it runs).
  OLLAMA_BASE_URL          Where to reach Ollama (default 192.168.87.160).
EOF
}

BRANCH="${ASSISTANT_UI_BRANCH:-main}"
while [ $# -gt 0 ]; do
  case "$1" in
    -b|--branch)
      [ $# -ge 2 ] || die "$1 requires a branch name"
      BRANCH="$2"
      shift 2
      ;;
    --branch=*)
      BRANCH="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      die "unknown option '$1'"
      ;;
    *)
      BRANCH="$1"
      shift
      ;;
  esac
done
[ -n "$BRANCH" ] || die "branch name must not be empty"

# Each deploy script runs as its own process, so the branch has to be handed
# over through the environment rather than a shell variable.
export ASSISTANT_UI_BRANCH="$BRANCH"

require_non_root

log "Deploying branch '$BRANCH' of alexvirt1/ai-assistant-ui-fastapi"

log "== preflight: prerequisites =="
if [ "${SKIP_PREREQS_INSTALL:-0}" = "1" ]; then
  log "SKIP_PREREQS_INSTALL=1, skipping prereqs install/verify"
else
  "$SCRIPT_DIR/install-prereqs.sh"
fi

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
