#!/usr/bin/env bash
# Installs the OS-level tooling every other script in this repo assumes is
# already on the host: git/curl/build tooling, Python 3.12 + Poetry (for
# assistant-ui-backend), and Node.js 20 + Corepack (for assistant-ui-frontend).
#
# Meant to be the first thing run on a clean Ubuntu VM that has none of this
# yet - deploy-all.sh runs it automatically. Idempotent: every step checks
# for the tool it would install first, and skips it if already present.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_non_root

PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
NODE_MAJOR="${NODE_MAJOR:-20}"
PY_BIN="python${PYTHON_VERSION}"

require_cmd apt-get
require_cmd sudo

log "== install-prereqs: apt base packages =="
sudo apt-get update
sudo apt-get install -y \
  git curl ca-certificates gnupg lsb-release \
  software-properties-common build-essential

log "== install-prereqs: Python ${PYTHON_VERSION} =="
if command -v "$PY_BIN" >/dev/null 2>&1; then
  log "$PY_BIN already installed: $($PY_BIN --version)"
else
  if ! apt-cache show "$PY_BIN" >/dev/null 2>&1; then
    log "$PY_BIN not available in configured repos, adding deadsnakes PPA"
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    sudo apt-get update
  fi
  sudo apt-get install -y "$PY_BIN" "${PY_BIN}-venv" "${PY_BIN}-dev"
fi
# Headers for building any Postgres driver that isn't a prebuilt wheel.
sudo apt-get install -y libpq-dev

log "== install-prereqs: Poetry (via ${PY_BIN}) =="
if command -v poetry >/dev/null 2>&1; then
  log "poetry already installed: $(poetry --version)"
else
  curl -sSL https://install.python-poetry.org | "$PY_BIN" -
fi

ensure_local_bin_on_path
POETRY_BIN_DIR="$HOME/.local/bin"
if [ ! -f /etc/profile.d/poetry-path.sh ]; then
  log "Adding $POETRY_BIN_DIR to PATH for future login shells (/etc/profile.d/poetry-path.sh)"
  printf 'export PATH="%s:$PATH"\n' "$POETRY_BIN_DIR" | sudo tee /etc/profile.d/poetry-path.sh >/dev/null
fi
require_cmd poetry

log "== install-prereqs: Node.js ${NODE_MAJOR}.x + Corepack =="
if command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge "$NODE_MAJOR" ]; then
  log "node already installed: $(node --version)"
else
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y nodejs
fi
sudo corepack enable
require_cmd corepack

cat <<EOF

== install-prereqs: done ==

  ${PY_BIN}: $(command -v "$PY_BIN")
  poetry:    $(poetry --version)
  node:      $(node --version)
  corepack:  enabled ($(command -v corepack))

Poetry's install dir ($POETRY_BIN_DIR) was added to PATH for this shell and
future login shells. If a *different* shell (e.g. a non-login one) still
can't find 'poetry', add $POETRY_BIN_DIR to its PATH manually.

EOF
