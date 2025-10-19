# Vault Docker Cluster

A reproducible HashiCorp Vault cluster lab that runs entirely on Docker. The stack spins up three Vault nodes using integrated storage (Raft), an auxiliary container that watches and auto-unseals sealed nodes, and an NGINX reverse proxy that presents a single entry point on `http://localhost:8200`.

## Architecture
- **vault-1 / vault-2 / vault-3** – Vault 1.20 servers backed by integrated Raft storage. Each node mounts a local config directory (`vault-*/config`) and data directory (`vault-*/data`).
- **vault-unsealer** – Lightweight helper container that tails each node and replays the generated `unseal.sh` script when a node becomes sealed.
- **load-balancer** – NGINX 1.29 front-end with IP-hash upstream balancing and health checks that proxies every request to one of the Vault nodes.

All services share the `vault_net` bridge network that Docker Compose creates.

## Prerequisites
- Docker Engine 24+
- Docker Compose v2 (`docker compose` CLI)
- `jq` (used by the initialization script)
- Optional but recommended: [`go-task`](https://taskfile.dev/#/installation) to run the predefined automation in `Taskfile.yml`

> **Heads-up:** The repository contains generated `unseal.sh` scripts and historic credential snapshots. Treat them as sensitive secrets or delete them before committing / publishing.

## Quick Start (Task runner)
```bash
# Build the custom Vault image (once)
docker build -f Dockerfile.vault -t vaultdockercluster:1.20 .

# Start, initialize, and configure the cluster interactively
task bootstrap
```
`task bootstrap` executes the following:
1. `task up` – starts the containers in the background.
2. Waits for the Vault API to come up.
3. Runs `init-and-generate-unseal.sh`, which:
   - Calls `vault operator init` against `vault-1`.
   - Prints the unseal keys + root token (and writes them to `vault-credentials-<timestamp>.md` and `vault-init-keys.json`).
   - Generates `vault-*/config/unseal.sh` helper scripts.
4. Prompts you to press Enter once you have stored the credentials safely.
5. Invokes `task setup-cluster` to unseal `vault-1`, join `vault-2` and `vault-3` to the Raft cluster, and unseal them.

Once bootstrap completes, browse the UI at `http://localhost:8200` (no TLS in this lab environment).

## Manual Workflow (without Task)
```bash
# Build the Vault image
docker build -f Dockerfile.vault -t vaultdockercluster:1.20 .

# Launch every container
docker compose up -d

# Initialize vault-1 and generate helper scripts
./init-and-generate-unseal.sh

# Run through the suggested follow-up steps printed by the script:
# - task setup-cluster (or equivalent docker compose exec commands)
```

### Useful Compose commands
- `docker compose ps` – show container status.
- `docker compose logs -f` – tail logs for all services.
- `docker compose exec vault-1 sh` – open a shell in a Vault node.
- `docker compose logs -f vault-unsealer` – watch the auto-unseal monitor activity.

## Day-2 Operations (Taskfile.yml)
Some common targets:
- `task status` – check each node’s `vault status` output.
- `task quick-check` – display only the sealed state & HA mode.
- `task cluster-check` – run a comprehensive health report (containers, raft peers, load balancer health endpoint).
- `task monitor-logs` / `task monitor-status` – follow the auto-unseal helper.
- `task restart` – restart the cluster and re-run the unseal helpers.
- `task reset` – **dangerous**: stops containers, wipes Raft data, and removes generated artefacts. Use this before re-initializing from scratch.

## Auto-Unseal Monitor
The `auto-unseal-monitor.sh` script runs in its own container (`vault-unsealer`).
- Polls each Vault node every 30 seconds via `vault status`.
- If a node transitions to `sealed`, reads the unseal keys from the mounted `unseal.sh` file and runs the three `vault operator unseal` commands.
- Retries up to three times per incident. Logs show timestamps and outcomes.

Because the helper executes the same unseal script stored on disk, protect the `vault-*/config/unseal.sh` files and remove them when no longer needed.

## Load Balancer
`nginx/nginx.conf` configures an upstream named `vault_servers` and:
- Uses `ip_hash` to keep UI sessions sticky.
- Forwards `X-Forwarded-*` headers required by Vault.
- Proxies `/health` to Vault’s `/v1/sys/health` endpoint.
- Disables compression and caching for safety.

## Data & Persistence
Each Vault node mounts `vault-*/data`, which retains Raft snapshots and WALs between restarts. Wiping these directories (see `task reset`) forces a clean initialization.

## Security Notes
- Generated credential files (`vault-credentials-*.md`, `vault-init-keys.json`, `vault-*/config/unseal.sh`) contain highly sensitive data. Move them to a secure vault or delete them immediately after testing.
- The root token printed during initialization has full privileges; rotate it or replace it with scoped tokens for real workloads.

## Troubleshooting
- `docker compose logs vault-1` – check Vault start-up messages.
- `task cluster-check` – verifies container state, raft peers, and load balancer health.
- `docker compose exec vault-1 vault operator raft list-peers` – confirm raft membership manually.
- `docker compose exec vault-1 vault status -format=json | jq '.'` – inspect detailed status fields.

If initialization fails with "Vault is already initialized", run `task reset` (or manually wipe `vault-*/data`) before trying again.

## Directory Layout
```
.
├── docker-compose.yaml        # Service definitions
├── Dockerfile.vault           # Custom Vault image (1.20, Istanbul TZ)
├── nginx/
│   ├── Dockerfile.nginx       # (Optional) custom nginx image base
│   └── nginx.conf             # Reverse proxy configuration
├── vault-*/config/            # Vault HCL configs + generated unseal scripts
├── vault-*/data/              # Raft storage persisted on host
├── init-and-generate-unseal.sh# Initialization helper
├── auto-unseal-monitor.sh     # Auto-unseal watchdog
├── Taskfile.yml               # go-task automation
└── vault-credentials-*.md     # Generated secret snapshots (delete or secure!)
```
