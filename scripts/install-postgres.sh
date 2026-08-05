#!/usr/bin/env bash
# Installs PostgreSQL locally (if not already installed) and provisions the
# role/database pair that assistant-ui-backend.service expects, listening
# on 127.0.0.1:5432, plus the two extensions the backend can make use of
# (pgvector and pg_trgm).
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

# pg_major
# The major version of the *running* server, not of whatever pg_config
# happens to be first on PATH: the extension packages are per-major
# (postgresql-16-pgvector installs into /usr/lib/postgresql/16/lib), so a
# host carrying two clusters must get the one that is actually serving.
pg_major() {
  sudo -u postgres psql -tAc "SHOW server_version_num" | awk '{ print int($1 / 10000) }'
}

# ensure_pgvector_package <major>
# pgvector ships as a separate apt package; core postgresql-contrib does not
# carry it. Non-fatal if unavailable - the backend falls back to computing
# similarity in Python over JSONB vectors, which is slower but correct.
ensure_pgvector_package() {
  local pkg="postgresql-${1}-pgvector"

  if dpkg -s "$pkg" >/dev/null 2>&1; then
    log "$pkg already installed"
    return 0
  fi

  # A host that has never run apt-get update in this session may simply not
  # know about the package yet; refresh once before believing it's missing.
  apt-cache show "$pkg" >/dev/null 2>&1 || sudo apt-get update
  if ! apt-cache show "$pkg" >/dev/null 2>&1; then
    warn "$pkg is not available from this host's apt sources (it lives in Ubuntu 'universe'); skipping pgvector"
    return 1
  fi

  sudo apt-get install -y "$pkg"
}

# ensure_extension <db> <extension>
# CREATE EXTENSION runs as the postgres superuser and is per-database, so it
# has to happen after the database exists. 'vector' is not a trusted
# extension, which is why the database owner cannot create it itself;
# 'pg_trgm' is trusted (PG13+) but is created here too so both land in one
# place. Neither needs shared_preload_libraries, so no restart follows.
ensure_extension() {
  local db="$1" ext="$2"

  if [ "$(sudo -u postgres psql -d "$db" -tAc "SELECT 1 FROM pg_extension WHERE extname='${ext}'")" = "1" ]; then
    log "Extension '$ext' already present in '$db'"
    return 0
  fi

  if sudo -u postgres psql -d "$db" -c "CREATE EXTENSION IF NOT EXISTS ${ext};" >/dev/null; then
    log "Created extension '$ext' in '$db'"
  else
    warn "Could not create extension '$ext' in '$db'; the backend degrades without it. Retry by hand with: sudo -u postgres psql -d ${db} -c 'CREATE EXTENSION ${ext};'"
    return 1
  fi
}

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
    # Hand the connection string to deploy-assistant-ui-backend.sh instead of
    # making you retype the same password into its DATABASE_URL prompt.
    save_database_url "postgresql://${role}:$(urlencode "$password")@127.0.0.1:5432/${db}"
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

log "== install-postgres: extensions =="
if [ "${SKIP_PGVECTOR_INSTALL:-0}" = "1" ]; then
  log "SKIP_PGVECTOR_INSTALL=1, leaving pgvector alone"
else
  # || true throughout: a missing extension degrades the backend, it does not
  # break it, so it must not abort a deploy under `set -e`.
  ensure_pgvector_package "$(pg_major)" \
    && ensure_extension "$ASSISTANT_UI_DB_NAME" vector \
    || true
fi
# Ships with postgresql-contrib, already installed above.
ensure_extension "$ASSISTANT_UI_DB_NAME" pg_trgm || true

check_postgres_running

cat <<EOF

== install-postgres: done ==

deploy-assistant-ui-backend.sh picks the DATABASE_URL up from
${ASSISTANT_UI_DB_ENV_FILE} automatically, so it will not
ask you for it. If that file is missing (e.g. the role predates this
script), it falls back to prompting - the value it wants is:

  postgresql://${ASSISTANT_UI_DB_ROLE}:<password>@127.0.0.1:5432/${ASSISTANT_UI_DB_NAME}

EOF
