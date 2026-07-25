#!/usr/bin/env bash
# Installs PostgreSQL locally (if not already installed) and provisions the
# role/database pair that assistant-ui-backend.service expects, listening
# on 127.0.0.1:5432.
#
# Idempotent: skips the apt install if postgresql is already present, skips
# creating the role/database if it already exists. Never overwrites an
# existing role's password.
#
# Passwords are never hardcoded here - they're read from environment
# variables you export beforehand, or prompted for interactively
# (non-echoing) the first time the role is created.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib.sh"

ASSISTANT_UI_DB_ROLE="${ASSISTANT_UI_DB_ROLE:-assistant_ui}"
ASSISTANT_UI_DB_NAME="${ASSISTANT_UI_DB_NAME:-assistant_ui}"

pg_role_exists() {
  local role="$1"
  [ "$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${role}'")" = "1" ]
}

pg_database_exists() {
  local db="$1"
  [ "$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'")" = "1" ]
}

# ensure_role_and_db <role> <db> <password-env-var>
ensure_role_and_db() {
  local role="$1" db="$2" pass_var="$3" password

  if pg_role_exists "$role"; then
    log "Role '$role' already exists, leaving its password untouched"
  else
    prompt_secret "$pass_var" "Set a password for new Postgres role '$role'"
    eval "password=\${$pass_var}"
    [ -n "$password" ] || die "No password provided for role '$role'"
    sudo -u postgres psql -c "CREATE ROLE ${role} LOGIN PASSWORD '${password}';" >/dev/null
    log "Created role '$role'"
  fi

  if pg_database_exists "$db"; then
    log "Database '$db' already exists"
  else
    sudo -u postgres createdb -O "$role" "$db"
    log "Created database '$db' owned by '$role'"
  fi
}

log "== install-postgres: package =="
if command -v psql >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^postgresql\.service'; then
  log "PostgreSQL already installed"
else
  require_cmd apt-get
  sudo apt-get update
  sudo apt-get install -y postgresql postgresql-contrib
fi

log "== install-postgres: enable + start service =="
sudo systemctl enable --now postgresql

log "== install-postgres: wait for it to accept connections =="
require_cmd pg_isready
for _ in $(seq 1 15); do
  sudo -u postgres pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && break
  sleep 1
done
sudo -u postgres pg_isready -h 127.0.0.1 -p 5432 || die "PostgreSQL did not become ready"

log "== install-postgres: assistant-ui-backend role/db =="
ensure_role_and_db "$ASSISTANT_UI_DB_ROLE" "$ASSISTANT_UI_DB_NAME" ASSISTANT_UI_DB_PASSWORD

check_postgres_running

cat <<EOF

== install-postgres: done ==

Use this when deploy-assistant-ui-backend.sh prompts for a DATABASE_URL for
its systemd drop-in (it is not written to disk by this script):

  postgresql://${ASSISTANT_UI_DB_ROLE}:<password>@127.0.0.1:5432/${ASSISTANT_UI_DB_NAME}

EOF
