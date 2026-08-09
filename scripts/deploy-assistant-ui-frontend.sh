#!/usr/bin/env bash
# Pulls alexvirt1/ai-assistant-ui-fastapi (if not already present)
# and (re)installs frontend/ as assistant-ui-frontend.service.
#
# Mirrors the exact working setup: pnpm build then `next start` on :3000,
# fronted by the frontend's own app/api/chat/route.ts, which proxies to
# the backend at http://127.0.0.1:8000/api/chat - so this service must
# run on the same host as assistant-ui-backend.
#
# Requires git and corepack (ships with Node.js 20+) on PATH - run
# scripts/install-prereqs.sh first on a host that doesn't have them yet.
#
# Idempotent: safe to re-run to pick up new commits, rebuild, and restart.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_non_root

# Corepack downloads the pnpm version pinned in package.json on first use;
# without this it prompts interactively, which hangs a non-interactive run.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

REPO_URL="${ASSISTANT_UI_REPO_URL:-https://github.com/alexvirt1/ai-assistant-ui-fastapi.git}"
REPO_DIR="${ASSISTANT_UI_DIR:-/opt/ai-agent-lab/ai-assistant-ui-fastapi}"
# Which branch to deploy. deploy-all.sh exports this from its --branch flag;
# set it directly to run this script standalone against e.g. dev.
BRANCH="${ASSISTANT_UI_BRANCH:-main}"
FRONTEND_DIR="$REPO_DIR/frontend"
SERVICE_NAME="assistant-ui-frontend"
SERVICE_USER="${SERVICE_USER:-ubuntu}"
PORT="${ASSISTANT_UI_FRONTEND_PORT:-3000}"

require_cmd git
require_cmd corepack

log "== assistant-ui-frontend: pull repo (branch: $BRANCH) =="
clone_or_update "$REPO_URL" "$REPO_DIR" "$BRANCH"

log "== assistant-ui-frontend: install + build =="
(cd "$FRONTEND_DIR" && corepack pnpm install && corepack pnpm build)

log "== assistant-ui-frontend: install systemd unit =="
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=assistant-ui Next.js frontend
After=network.target assistant-ui-backend.service
Requires=assistant-ui-backend.service

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${FRONTEND_DIR}
Environment=NODE_ENV=production
Environment=PORT=${PORT}
Environment=HOSTNAME=0.0.0.0
ExecStart=/usr/bin/corepack pnpm start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log "== assistant-ui-frontend: enable + restart =="
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

sleep 2
sudo systemctl status "$SERVICE_NAME" --no-pager || true

log "== assistant-ui-frontend: health check =="
if curl -fsSI "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
  log "OK: http://127.0.0.1:${PORT}/ is responding"
else
  warn "Health check failed - inspect: journalctl -u $SERVICE_NAME -n 80 --no-pager"
fi
