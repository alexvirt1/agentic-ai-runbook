#!/usr/bin/env bash
# Read-only precondition check for the local PostgreSQL service that
# assistant-ui-backend.service depends on.
# Never creates or modifies anything.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib.sh"

ASSISTANT_UI_DB_NAME="${ASSISTANT_UI_DB_NAME:-assistant_ui}"

echo "-- systemd unit --"
systemctl status postgresql --no-pager || true

echo
echo "-- listening sockets --"
ss -ltnp 2>/dev/null | grep 5432 || echo "nothing listening on 5432"

echo
echo "-- databases (requires local sudo -u postgres access) --"
sudo -u postgres psql -c '\l' 2>&1 || echo "could not query databases (need sudo/postgres access)"

echo
echo "-- roles --"
sudo -u postgres psql -c '\du' 2>&1 || echo "could not query roles (need sudo/postgres access)"

# Both are optional - the backend degrades rather than failing without them -
# so this reports their state instead of treating absence as an error.
echo
echo "-- extensions in '${ASSISTANT_UI_DB_NAME}' (vector = ANN retrieval, pg_trgm = chat search) --"
sudo -u postgres psql -d "$ASSISTANT_UI_DB_NAME" -c \
  "SELECT e.name, e.default_version AS available, e.installed_version AS created
     FROM pg_available_extensions e
    WHERE e.name IN ('vector', 'pg_trgm')
    ORDER BY e.name;" 2>&1 \
  || echo "could not query extensions (database '${ASSISTANT_UI_DB_NAME}' missing, or no sudo/postgres access)"

check_postgres_running && log "PostgreSQL appears ready for assistant-ui-backend."
