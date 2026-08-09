# AI Homelab Runbook

Rebuild/setup documentation and scripts for the local AI agent stack running
on this host (`ai-2`). Captures the current known-good state as executable
documentation so the stack can be reinstalled or moved to a new host without
re-deriving everything from the chat history in `chat-scripts.md`.

## Architecture

```mermaid
flowchart TD
    Browser(["Browser"])

    subgraph UI["assistant-ui stack — alexvirt1/ai-assistant-ui-fastapi"]
        Frontend["assistant-ui-frontend :3000<br/>Next.js (frontend/)"]
        Backend["assistant-ui-backend :8000<br/>FastAPI + LangGraph (backend/)"]
        Frontend -- "POST /api/chat<br/>(route.ts proxy)" --> Backend
    end

    Ollama[("ollama.service :11434<br/>same VM or separate GPU VM")]
    Postgres[("PostgreSQL :5432<br/>local")]

    Browser --> Frontend
    Backend --> Ollama
    Backend --> Postgres
```

`assistant-ui-backend` and `assistant-ui-frontend` must run on the same
host, since the frontend proxies to the backend at `127.0.0.1:8000`.

## Repos and services

| Repo | Deploys to | systemd service | Port |
| --- | --- | --- | --- |
| [alexvirt1/ai-assistant-ui-fastapi](https://github.com/alexvirt1/ai-assistant-ui-fastapi/) `backend/` | `/opt/ai-agent-lab/
ai-assistant-ui-fastapi/backend` | `assistant-ui-backend.service` | 8000 |
| same repo, `frontend/` | `/opt/ai-agent-lab/
ai-assistant-ui-fastapi/frontend` | `assistant-ui-frontend.service` | 3000 |

## Prerequisites

All you need by hand is a clean Ubuntu VM with `sudo` access — no `git`,
`curl`, Python, Poetry, or Node required beforehand. `scripts/install-prereqs.sh`
installs all of it:

- Base tooling: `git`, `curl`, `build-essential`, `libpq-dev`, etc.
- Python 3.12 (`python3.12`), via the deadsnakes PPA if the host's own repos
  don't carry it yet
- [Poetry](https://python-poetry.org/), installed against `python3.12` — used
  for the assistant-ui backend
- Node.js 20 with Corepack enabled — used for the frontend (pnpm via corepack)

It's idempotent (skips anything already installed) and safe to re-run.
`deploy-all.sh` runs it automatically as the first step; set
`SKIP_PREREQS_INSTALL=1` to skip it (e.g. you've already run it once and
just want to save the apt/PATH checks).

Neither PostgreSQL nor Ollama need to be installed by hand either —
`scripts/install-postgres.sh` and `scripts/install-ollama.sh` handle those.
Check readiness at any time with:

```bash
scripts/check-postgres.sh
```

## Quick start

**1. Get Ollama running somewhere reachable.** This can be this same host or
a separate (typically GPU) VM — the lab default is a dedicated GPU VM at
`192.168.87.160`:

```bash
# on whichever host should serve models:
scripts/install-ollama.sh
```

`deploy-all.sh` below only checks that Ollama is reachable at
`OLLAMA_BASE_URL` (default `http://192.168.87.160:11434`); it never installs
Ollama itself, since that host is frequently not the one running this repo.
If you're running Ollama on this same host, either re-run with
`OLLAMA_LISTEN_HOST=127.0.0.1 scripts/install-ollama.sh` and
`OLLAMA_BASE_URL=http://127.0.0.1:11434 scripts/deploy-all.sh`, or leave the
default `0.0.0.0` binding — it also works for local callers.

**2. On the app host, deploy the rest** (idempotent — safe to re-run, and
works on a completely clean VM with nothing preinstalled but `sudo`):

```bash
cd /opt/ai-agent-lab/agentic-ai-runbook
scripts/deploy-all.sh
```

This installs OS-level prerequisites (Python 3.12 + Poetry, Node 20 +
Corepack, build tools), installs/verifies Postgres, checks Ollama is
reachable, then runs the two deploy scripts below in sequence, then curls
both health endpoints.

### Deploying a branch other than `main`

`deploy-all.sh` deploys `main` by default. To try a branch before it's
merged, pass its name (as a positional argument or via `-b`/`--branch`):

```bash
scripts/deploy-all.sh dev                # deploy the dev branch
scripts/deploy-all.sh --branch feat/xyz  # any other branch
scripts/deploy-all.sh                    # back to main
```

Both services always come from the same branch, and each run re-installs
dependencies and rebuilds from it, so switching back is just another run
with the other branch name. The flag is passed to the individual scripts
as `ASSISTANT_UI_BRANCH`, so they can be run standalone the same way:

```bash
ASSISTANT_UI_BRANCH=dev scripts/deploy-assistant-ui-frontend.sh
```

An unknown branch name fails fast, before anything is deployed. If the
checkout at `ASSISTANT_UI_DIR` has uncommitted local edits, the switch is
skipped with a warning rather than clobbering them.

## Individual scripts

Run these on their own if you only need to install/update one piece.

```bash
scripts/install-prereqs.sh                # git/build tools, Python 3.12 + Poetry, Node 20 + Corepack
scripts/install-ollama.sh                 # Ollama                        (:11434)
scripts/install-postgres.sh               # PostgreSQL + role/db provisioning
scripts/deploy-assistant-ui-backend.sh    # assistant-ui-backend.service   (:8000)
scripts/deploy-assistant-ui-frontend.sh   # assistant-ui-frontend.service  (:3000)
```

### `install-prereqs.sh`

Idempotent OS-tooling bootstrap, meant to be run first on a host that has
none of this yet:

1. Installs base apt packages: `git`, `curl`, `build-essential`, `libpq-dev`,
   etc.
2. Installs Python 3.12 (`python3.12`, `-venv`, `-dev`) — adds the
   `deadsnakes` PPA first if the host's own repos don't carry it (e.g.
   Ubuntu 22.04).
3. Installs [Poetry](https://python-poetry.org/) via its official installer,
   run against `python3.12` specifically, and adds its install dir
   (`~/.local/bin`) to `PATH` for this run and future login shells (via
   `/etc/profile.d/poetry-path.sh`).
4. Installs Node.js 20 via the NodeSource setup script (skipped if a
   Node 20+ is already present), then runs `corepack enable` so `pnpm` is
   available through Corepack.

`deploy-all.sh` runs this automatically; set `SKIP_PREREQS_INSTALL=1` to
skip it. Override versions with `PYTHON_VERSION` (default `3.12`) or
`NODE_MAJOR` (default `20`).

`deploy-assistant-ui-backend.sh` pins the backend's Poetry venv to this
Python version explicitly (`poetry env use python3.12`), so it stays 3.12
even if the host's default `python3` is something else.

### `install-ollama.sh`

Idempotent Ollama bootstrap, meant to be run directly on whichever host
should serve models (not necessarily the same one running the rest of this
repo):

1. Installs Ollama via its official installer
   (`curl -fsSL https://ollama.com/install.sh | sh`) if the `ollama` binary
   isn't already present.
2. Writes the base `ollama.service` unit.
3. Detects an NVIDIA GPU (`nvidia-smi -L`). If present, writes a drop-in
   (`ollama.service.d/override.conf`) that waits for
   `nvidia-persistenced.service` and the GPU to enumerate before starting,
   and pins `CUDA_VISIBLE_DEVICES=0`. If no GPU is found, writes the same
   drop-in without the GPU-specific bits, so it also works for a CPU-only
   or same-VM setup.
4. Either way, the drop-in sets the lab's known-good tuning:
   `OLLAMA_CONTEXT_LENGTH=8192`, `OLLAMA_NUM_PARALLEL=1`,
   `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_MAX_QUEUE=32`,
   `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`, and
   `OLLAMA_HOST` (default `0.0.0.0`, so other hosts on the LAN can reach
   it — set `OLLAMA_LISTEN_HOST=127.0.0.1` to keep it local-only).
5. Enables, restarts, and health-checks the service.
6. Prints the `ollama pull <model>` command for the model this stack
   expects (`qwen3:8b` by default) instead of pulling it automatically —
   set `PULL_MODEL=1` to have the script pull it for you.

All values are overridable via env vars of the same name shown above (e.g.
`OLLAMA_CONTEXT_LENGTH=16384 scripts/install-ollama.sh`).

If Ollama ends up on a separate host from the rest of the stack and you use
a firewall, open the port to your lab subnet, e.g.
`sudo ufw allow from 192.168.87.0/24 to any port 11434 proto tcp`.

### `install-postgres.sh`

Idempotent PostgreSQL bootstrap:

1. Installs the `postgresql`/`postgresql-contrib` apt packages if `psql`
   and the `postgresql` systemd unit aren't already present.
2. Enables and starts the `postgresql` service, waits for it to accept
   connections on `127.0.0.1:5432`.
3. Creates the `assistant_ui` / `assistant_ui` role/database that
   `assistant-ui-backend.service` expects, **only if it doesn't already
   exist** (an existing role keeps its existing password — this script
   never resets one).
4. Installs and creates the two extensions the backend can take advantage
   of, in that database (see **Database extensions** below). Both are
   best-effort: a failure warns and continues, because the backend degrades
   rather than breaking without them.
5. Records the resulting `DATABASE_URL` in
   `/etc/ai-agent-lab/assistant-ui-db.env` (root-owned, `0600`) so
   `deploy-assistant-ui-backend.sh` can reuse it — you only ever type the
   database password once. Override the location with
   `ASSISTANT_UI_DB_ENV_FILE`.

Role/database name are overridable via `ASSISTANT_UI_DB_ROLE`,
`ASSISTANT_UI_DB_NAME`. The password is read from `ASSISTANT_UI_DB_PASSWORD`
if pre-exported, otherwise prompted for interactively (non-echoing) the
first time the role is created.

`deploy-all.sh` runs this automatically; set `SKIP_POSTGRES_INSTALL=1` to
skip it and just verify an existing Postgres instance is up instead (e.g.
if Postgres is managed outside this repo).

#### Database extensions

| Extension | Package | What uses it |
| --- | --- | --- |
| `vector` (pgvector) | `postgresql-<major>-pgvector` (Ubuntu `universe`) | Embedding similarity for document retrieval |
| `pg_trgm` | `postgresql-contrib`, already installed | Trigram index behind chat-history search |

Both are created in the `assistant_ui` database, and both are optional —
the backend works without either, so `install-postgres.sh` warns and
carries on rather than failing a deploy. Without `vector`, embeddings stay
in `JSONB` and similarity is computed in Python (fine per-document, slow
across a whole corpus). Without `pg_trgm`, chat search falls back to an
unindexed `ILIKE` scan.

Notes worth knowing when this misbehaves:

- The pgvector package is **per major version** — `postgresql-16-pgvector`
  installs into `/usr/lib/postgresql/16/lib`. The script reads the major
  from the *running* server (`SHOW server_version_num`), so a host with two
  clusters gets the one actually serving. Upgrading the server major means
  installing the matching package again.
- `vector` is not a [trusted extension](https://www.postgresql.org/docs/16/sql-createextension.html),
  so `CREATE EXTENSION` needs superuser — hence `sudo -u postgres`, not the
  `assistant_ui` role. `pg_trgm` *is* trusted (PG13+) and the owning role
  could create it itself; the script does both in one place regardless.
- Neither is a `shared_preload_libraries` extension, so no Postgres restart
  is needed after installing them.
- Skip the pgvector half entirely with `SKIP_PGVECTOR_INSTALL=1` (e.g. an
  air-gapped host, or a managed Postgres where you provision extensions
  yourself). `pg_trgm` is always attempted — it needs no extra package.

To add them to a database that predates this script:

```bash
sudo apt-get install -y "postgresql-$(sudo -u postgres psql -tAc 'SHOW server_version_num' | awk '{print int($1/10000)}')-pgvector"
sudo -u postgres psql -d assistant_ui -c 'CREATE EXTENSION IF NOT EXISTS vector;'
sudo -u postgres psql -d assistant_ui -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'
```

### The two `deploy-*.sh` scripts

Each one:

1. Clones the repo on first run; on later runs, fast-forward pulls the
   latest commit of the selected branch — `main` unless
   `ASSISTANT_UI_BRANCH` says otherwise (stops and warns instead of
   clobbering if the checkout has local edits).
2. Installs/updates dependencies (shared venv, Poetry in-project venv, or
   pnpm, depending on the service).
3. Creates a `.env` with sane non-secret defaults **only if one doesn't
   already exist** — existing `.env` files are never overwritten.
4. Writes the systemd unit to `/etc/systemd/system/` (requires `sudo`).
5. Reloads systemd, enables and (re)starts the service.
6. Runs a `curl` health check.

You'll be prompted for `sudo` (for the systemd steps) and possibly for a
Postgres connection string (see **Secrets** below).

## Secrets

Nothing in this repo or in `scripts/` contains real credentials.

- `install-postgres.sh` role password — read from `ASSISTANT_UI_DB_PASSWORD`
  if pre-exported, otherwise prompted for interactively (non-echoing). The
  password itself is never written to disk on its own; the connection string
  built from it is (see next point).
- `assistant-ui-backend` — `DATABASE_URL` is **not** put in the repo or the
  main unit file. It lives in two root-owned `0600` files:
  `/etc/ai-agent-lab/assistant-ui-db.env`, written by `install-postgres.sh`
  when it creates the role, and the systemd drop-in
  `/etc/systemd/system/assistant-ui-backend.service.d/override.conf`, which
  `deploy-assistant-ui-backend.sh` derives from it. So the password is typed
  once, at role creation. The deploy script resolves the URL in this order:
  `ASSISTANT_UI_DATABASE_URL` if pre-exported → the recorded file → an
  interactive, non-echoing prompt (the fallback when the role predates this
  script). Re-running either script leaves an existing drop-in untouched.

  Passwords containing `@ : / ? # %` are percent-encoded automatically when
  the URL is built, so no manual escaping is needed at the prompt. The `%`
  that encoding introduces is then doubled (`%23` → `%%23`) when the URL is
  written into the systemd drop-in, because `%` starts a *specifier* in unit
  files — see the "Invalid slot" entry under **Troubleshooting**.
- Non-secret config (`OLLAMA_BASE_URL`, `OLLAMA_MODEL`, `OLLAMA_NUM_CTX`) is
  filled in with real homelab values since these aren't credentials.

## Security

This stack has no authentication layer — the frontend, backend API, and
Ollama endpoint are all reachable by anyone who can route to their ports.
This is intentional: the framework is designed for single-user use on a
trusted home/lab network, not for multi-tenant or internet-facing
deployment. If you expose any of these services beyond your trusted LAN
(e.g. port-forwarding, a public reverse proxy, or a shared network), put
your own authentication/authorization layer in front of them first.

## Overriding defaults

All scripts read their inputs from environment variables with sensible
defaults, so you can point them at a different host/layout without editing
the scripts:

```bash
ASSISTANT_UI_DIR=/srv/ai-assistant-ui-fastapi \
ASSISTANT_UI_BRANCH=dev \
SERVICE_USER=deploy \
scripts/deploy-all.sh
```

See the top of each script for the full list of variables it honors.

## Validating a deploy

```bash
curl -s http://<ollama-host>:11434/api/tags | jq
curl -s http://127.0.0.1:8000/openapi.json | jq '.paths | keys'
curl -I http://127.0.0.1:3000/
```

Then in a browser, open `http://<server-ip>:3000`, ask "What time is it?",
and confirm the tool call in the backend log:

```bash
journalctl -u assistant-ui-backend -n 50 --no-pager | grep 'TOOL EXECUTED'
```

Confirm Postgres persistence (same `thread_id`/browser session across two
messages should recall earlier facts):

```bash
sudo -u postgres psql -d assistant_ui -c \
  "SELECT thread_id, count(*) FROM checkpoints GROUP BY thread_id ORDER BY count(*) DESC;"
```

Confirm the extensions are created (`installed_version` non-empty for both;
`scripts/check-postgres.sh` prints the same thing):

```bash
sudo -u postgres psql -d assistant_ui -c \
  "SELECT name, default_version, installed_version FROM pg_available_extensions
    WHERE name IN ('vector', 'pg_trgm');"
```

## Operating the services

```bash
sudo systemctl status  assistant-ui-backend assistant-ui-frontend --no-pager
sudo systemctl restart assistant-ui-backend assistant-ui-frontend
journalctl -u <service-name> -f
```

## Troubleshooting

- **`ERROR: run this as your regular user, not root/sudo`** — you invoked a
  script with a leading `sudo` (e.g. `sudo scripts/deploy-all.sh`). Don't —
  every script here calls `sudo` itself for the specific steps that need it
  (apt installs, systemctl, `/etc/systemd` writes) and will prompt you.
  Running the whole thing as root makes `$HOME=/root`, so Poetry, the
  cloned repo, and the pnpm store end up owned by root instead of by
  `SERVICE_USER` (`ubuntu` by default) — which the systemd services run as
  and won't be able to read/execute. Re-run without `sudo`. If you already
  hit this once, clean up what it left behind first:
  `sudo rm -f /etc/profile.d/poetry-path.sh` (it was pointing at
  `/root/.local/bin`, which your regular user can't read anyway).
- **`required command 'poetry' not found on PATH`** even right after
  `install-prereqs.sh` reported it installed — each script here runs as its
  own process, so a `PATH` export made by one script never carries over to
  the next; only `/etc/profile.d` (future *login* shells) persists it. This
  is handled automatically now (`ensure_local_bin_on_path` in `lib.sh` runs
  before `require_cmd poetry` in every script that needs it), but if you
  still hit it, check `~/.local/bin/poetry` exists and `echo $HOME` matches
  the user you expect (see the root/sudo item above).
- **`status=203/EXEC`** in `systemctl status` — the `ExecStart` binary path
  doesn't exist under systemd's environment. Check with
  `command -v <binary>` and compare to the path baked into the unit file.
- **Backend starts but `/api/chat` 404s / no persistence** — `DATABASE_URL`
  drop-in is missing or wrong; check
  `systemctl cat assistant-ui-backend` and `journalctl -u assistant-ui-backend`.
- **`Failed to resolve specifiers in DATABASE_URL=...: Invalid slot`** — the
  drop-in has an unescaped `%`. In unit files `%` starts a specifier (`%i`,
  `%n`, …), so a percent-encoded password (`#` → `%23`) makes systemd fail to
  expand it and **discard the whole `Environment=` line**. The service still
  starts and its health check still passes — it just runs with no Postgres
  persistence, which is what makes this easy to miss. `deploy-assistant-ui-backend.sh`
  now doubles each `%` when writing the drop-in, but it never rewrites an
  existing one, so a drop-in created before this fix keeps the bad value
  (the script warns about it on re-run). To repair a host:

  ```bash
  sudo rm /etc/systemd/system/assistant-ui-backend.service.d/override.conf
  scripts/deploy-assistant-ui-backend.sh    # re-creates it, correctly escaped
  ```

  Confirm the variable actually reached the service (the deploy script now
  checks this automatically too — note this prints the password):

  ```bash
  systemctl show -p Environment assistant-ui-backend
  ```
- **`password authentication failed for user "assistant_ui"`** — the drop-in's
  password doesn't match the role's. `install-postgres.sh` never resets an
  existing role's password, so this happens when the role was created outside
  these scripts, or the drop-in was filled in by hand. Fix by resetting both:
  ```bash
  sudo -u postgres psql -c "ALTER ROLE assistant_ui PASSWORD 'newpass';"
  sudo rm /etc/ai-agent-lab/assistant-ui-db.env \
          /etc/systemd/system/assistant-ui-backend.service.d/override.conf
  ```
  then re-run `scripts/deploy-assistant-ui-backend.sh` and enter
  `postgresql://assistant_ui:newpass@127.0.0.1:5432/assistant_ui` at the prompt.
- **`could not open extension control file ".../vector.control"`** — the
  pgvector package is missing for the major version that's actually
  running. Check which that is with
  `sudo -u postgres psql -tAc 'SHOW server_version_num'` (e.g. `160014` →
  major 16) and install `postgresql-16-pgvector`. A host upgraded from one
  major to the next hits this with the old package still installed.
- **`permission denied to create extension "vector"`** — you ran
  `CREATE EXTENSION` as `assistant_ui`. pgvector isn't a trusted extension,
  so it needs `sudo -u postgres psql -d assistant_ui -c 'CREATE EXTENSION
  vector;'`. (`pg_trgm` is trusted and works either way.)
- **Frontend loads but chat fails** — confirm
  `frontend/app/api/chat/route.ts` still points at
  `http://127.0.0.1:8000/api/chat`, and that `assistant-ui-backend` is
  active on the same host.
- **`ollama.service` stuck `activating` on a GPU host** — the
  `ExecStartPre` GPU wait loop (`nvidia-smi -L | grep -q GPU`) never
  succeeds. Check `nvidia-smi` works at all outside systemd, and that the
  NVIDIA driver/`nvidia-persistenced` came up; see
  `journalctl -u ollama -n 80 --no-pager`.
- **Backends can't reach Ollama across the LAN** — confirm `OLLAMA_HOST` on
  the Ollama host is `0.0.0.0` (not `127.0.0.1`), and that its firewall
  allows the app host's IP on port `11434`.
- **Full historical context** for how this stack was built, debugged, and
  every dead end along the way: `chat-scripts.md` in this repo.
