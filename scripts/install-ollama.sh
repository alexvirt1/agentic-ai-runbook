#!/usr/bin/env bash
# Installs Ollama and runs it as ollama.service, tuned the same way as the
# lab's known-good config.
#
# Run this on whichever host will actually serve models - that can be this
# same VM (set OLLAMA_HOST=127.0.0.1 if nothing else needs LAN access to it)
# or a dedicated GPU VM (the default, OLLAMA_HOST=0.0.0.0, so the
# assistant-ui-backend service on another host can reach it over the LAN).
#
# Idempotent: safe to re-run to pick up new tuning values and restart the
# service. Uses Ollama's own official installer
# (https://ollama.com/download/linux) when the binary isn't present yet.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/lib.sh"

OLLAMA_LISTEN_HOST="${OLLAMA_LISTEN_HOST:-0.0.0.0}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-8192}"
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"
OLLAMA_MAX_QUEUE="${OLLAMA_MAX_QUEUE:-32}"
OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3:8b}"
PULL_MODEL="${PULL_MODEL:-0}"

log "== install-ollama: binary =="
if command -v ollama >/dev/null 2>&1; then
  log "ollama binary already installed ($(command -v ollama))"
else
  require_cmd curl
  log "Running Ollama's official installer"
  curl -fsSL https://ollama.com/install.sh | sh
  command -v ollama >/dev/null 2>&1 || die "ollama install appears to have failed"
fi

if ! id ollama >/dev/null 2>&1; then
  log "Creating system user 'ollama' (installer usually does this already)"
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin ollama
fi

HAS_GPU=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L 2>/dev/null | grep -q GPU; then
  HAS_GPU=1
  log "NVIDIA GPU detected: $(nvidia-smi -L | head -1)"
else
  log "No NVIDIA GPU detected - installing CPU-only tuning (skipping CUDA_VISIBLE_DEVICES and GPU wait)"
fi

log "== install-ollama: base systemd unit =="
sudo tee /etc/systemd/system/ollama.service >/dev/null <<'EOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"

[Install]
WantedBy=default.target
EOF

log "== install-ollama: tuning drop-in =="
sudo mkdir -p /etc/systemd/system/ollama.service.d

if [ "$HAS_GPU" = "1" ]; then
  sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<EOF
[Unit]
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
ExecStartPre=/bin/sh -c 'until /usr/bin/nvidia-smi -L | grep -q GPU; do sleep 1; done'
Environment="OLLAMA_HOST=${OLLAMA_LISTEN_HOST}"
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
Environment="OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}"
Environment="OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}"
Environment="OLLAMA_MAX_QUEUE=${OLLAMA_MAX_QUEUE}"
Environment="OLLAMA_FLASH_ATTENTION=${OLLAMA_FLASH_ATTENTION}"
Environment="OLLAMA_KV_CACHE_TYPE=${OLLAMA_KV_CACHE_TYPE}"
EOF
else
  sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_LISTEN_HOST}"
Environment="OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
Environment="OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}"
Environment="OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}"
Environment="OLLAMA_MAX_QUEUE=${OLLAMA_MAX_QUEUE}"
Environment="OLLAMA_FLASH_ATTENTION=${OLLAMA_FLASH_ATTENTION}"
Environment="OLLAMA_KV_CACHE_TYPE=${OLLAMA_KV_CACHE_TYPE}"
EOF
fi

log "== install-ollama: enable + restart =="
sudo systemctl daemon-reload
sudo systemctl enable --now ollama
sudo systemctl restart ollama

sleep 2
sudo systemctl status ollama --no-pager || true

log "== install-ollama: health check =="
CHECK_HOST="127.0.0.1"
[ "$OLLAMA_LISTEN_HOST" = "0.0.0.0" ] || CHECK_HOST="$OLLAMA_LISTEN_HOST"
if curl -fsS "http://${CHECK_HOST}:11434/api/tags" >/dev/null 2>&1; then
  log "OK: http://${CHECK_HOST}:11434/api/tags is responding"
else
  warn "Health check failed - inspect: journalctl -u ollama -n 80 --no-pager"
fi

if [ "$PULL_MODEL" = "1" ]; then
  log "== install-ollama: pulling ${OLLAMA_MODEL} =="
  ollama pull "$OLLAMA_MODEL"
else
  log "Skipping model pull. Pull the model this stack expects with:"
  log "  ollama pull ${OLLAMA_MODEL}"
  log "(or re-run with PULL_MODEL=1 to do it automatically)"
fi

cat <<EOF

== install-ollama: done ==

If this host is reachable over the LAN, other hosts should point at it via:
  OLLAMA_BASE_URL=http://$(hostname -I 2>/dev/null | awk '{print $1}'):11434

If OLLAMA_HOST was left at 0.0.0.0, remember to open the firewall for LAN
callers if you use one, e.g.:
  sudo ufw allow from <lab-subnet> to any port 11434 proto tcp

EOF
