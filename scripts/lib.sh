#!/usr/bin/env bash
# Shared helpers for the deploy-*.sh scripts in this directory.
# Sourced, not executed directly.

log()  { echo "[deploy] $*"; }
warn() { echo "[deploy] WARNING: $*" >&2; }
die()  { echo "[deploy] ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}

# require_non_root
# These scripts call sudo themselves for the specific steps that need it
# (apt installs, systemctl, writes under /etc/systemd). Running the whole
# script as root (e.g. `sudo scripts/deploy-all.sh`) instead makes
# $HOME=/root, so anything installed for the invoking user - Poetry, the
# cloned assistant-ui repo, the pnpm store - ends up root-owned. The
# systemd services then run as SERVICE_USER (ubuntu by default) and can't
# reliably read/execute root-owned files.
require_non_root() {
  if [ "$(id -u)" -eq 0 ]; then
    die "run this as your regular user, not root/sudo - it calls sudo itself for the specific steps that need it. Running the whole script as root leaves \$HOME=/root, so files it creates (Poetry, the cloned repo, pnpm) end up owned by root instead of '${SERVICE_USER:-ubuntu}', which is what the systemd services run as."
  fi
}

# ensure_local_bin_on_path
# Poetry's installer puts the 'poetry' binary in ~/.local/bin, which isn't
# guaranteed to be on PATH here: each script in this repo runs as its own
# process, so a PATH export made by one script (e.g. install-prereqs.sh)
# does not carry over to the next one deploy-all.sh invokes, and the
# /etc/profile.d entry install-prereqs.sh writes only helps *future login
# shells*, not the current automated run. Call this before require_cmd
# poetry in any script that needs it.
ensure_local_bin_on_path() {
  local dir="$HOME/.local/bin"
  if [ -d "$dir" ] && [[ ":$PATH:" != *":$dir:"* ]]; then
    export PATH="$dir:$PATH"
  fi
}

# clone_or_update <git-url> <target-dir> [branch]
# Clones on first run. On later runs, fast-forwards only; if the working
# tree has local edits it stops rather than clobbering them.
clone_or_update() {
  local url="$1" dir="$2" branch="${3:-main}"

  if [ -d "$dir/.git" ]; then
    log "Repo already present at $dir, fetching latest '$branch'"
    git -C "$dir" fetch origin "$branch"
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
      warn "$dir has local/uncommitted changes; leaving it as-is. Resolve manually, then re-run."
      return 0
    fi
    git -C "$dir" checkout "$branch"
    git -C "$dir" merge --ff-only "origin/$branch"
  else
    log "Cloning $url -> $dir"
    mkdir -p "$(dirname "$dir")"
    git clone --branch "$branch" "$url" "$dir"
  fi
}

# ensure_env_file <path> <heredoc-content>
# Never overwrites an existing .env (may hold live secrets already tuned
# for this host) - only creates it from the given defaults when missing.
ensure_env_file() {
  local path="$1" content="$2"
  if [ -f "$path" ]; then
    log ".env already exists at $path, leaving it untouched"
  else
    log "Creating $path with default values (edit it before relying on it)"
    printf '%s\n' "$content" > "$path"
  fi
}

# check_postgres_running
# Read-only precondition check. This project assumes PostgreSQL is already
# installed and running locally - these scripts never install or configure
# it, and never create databases/roles (that requires secrets only you
# should choose).
check_postgres_running() {
  if ! systemctl is-active --quiet postgresql 2>/dev/null; then
    warn "systemd unit 'postgresql' is not active. Start/enable local PostgreSQL before running the backend services."
    return 1
  fi
  if command -v pg_isready >/dev/null 2>&1; then
    if pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
      log "PostgreSQL is accepting connections on 127.0.0.1:5432"
    else
      warn "PostgreSQL service is active but not accepting connections on 127.0.0.1:5432 yet"
    fi
  fi
  return 0
}

# prompt_secret <var-name> <prompt-text>
# Reads a secret from the environment if already exported, otherwise
# prompts interactively without echoing it. Never hardcode secrets in
# these scripts or in git.
prompt_secret() {
  local __var="$1" __prompt="$2"
  local __current
  eval "__current=\${$__var:-}"
  if [ -z "$__current" ]; then
    read -r -s -p "$__prompt: " __current
    echo
  fi
  eval "$__var=\"\$__current\""
}
