#!/usr/bin/env bash
# Read-only precondition check for the local PostgreSQL service that
# assistant-ui-backend.service depends on.
# Never creates or modifies anything.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib.sh"

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

check_postgres_running && log "PostgreSQL appears ready for assistant-ui-backend."
