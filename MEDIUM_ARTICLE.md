# Building a High-Availability Vault Cluster with Docker and Raft Storage

![Vault Cluster Architecture](https://images.unsplash.com/photo-1633356122544-f134ef2944f5?w=1200&h=400&fit=crop)

## Introduction

HashiCorp Vault is one of the most powerful secrets management solutions in the industry. However, setting up a production-ready, highly-available Vault cluster can be intimidating. In this article, I'll walk you through building a **3-node Vault cluster using Docker** with **automatic unsealing**, **Raft-based storage**, and **infrastructure-as-code automation**.

By the end of this guide, you'll have a resilient secrets management infrastructure that can handle node failures and scale horizontally.

---

## Why Vault? Why High-Availability?

### The Problem

In modern infrastructure:
- Secrets are scattered across multiple systems (databases, APIs, certificates)
- No single source of truth for credential rotation
- Compliance requirements demand audit trails
- Manual secret management is error-prone

### The Solution

Vault provides:
- **Centralized secret management** - Single source of truth
- **Encryption as a service** - Encrypt/decrypt without exposing keys
- **Dynamic credentials** - Automatically generate short-lived credentials
- **Audit logging** - Complete trail of who accessed what and when
- **High availability** - Never lose access to your secrets

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                 Docker Compose Network                  │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │  Vault Node  │  │  Vault Node  │  │  Vault Node  │   │
│  │     (1)      │  │     (2)      │  │     (3)      │   │
│  └──────────────┘  └──────────────┘  └──────────────┘   │
│         │                 │                  │          │
│  ┌──────┴─────────────────┼──────────────────┴────┐     │
│  │                  Raft Consensus                │     │
│  └────────────────────────────────────────────────┘     │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │   Nginx Load Balancer (Optional)                 │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

Our setup features:
- **3 Vault nodes** for true high-availability
- **Raft storage backend** - No external dependencies (unlike Consul)
- **Auto-unsealing** - Automatic node recovery without manual intervention
- **Docker Compose orchestration** - Easy to deploy and manage
- **Health checks** - Automatic failure detection

---

## Prerequisites

Before we begin, make sure you have:

```bash
- Docker & Docker Compose (v3.8+)
- Taskfile CLI (for task automation)
- curl (for API testing)
```

Install the requirements:

```bash
# macOS
brew install docker docker-compose task jq curl

# Linux
sudo apt-get install docker.io docker-compose taskfile jq curl
```

---

## Project Structure

```
vault-docker-cluster/
├── docker-compose.yaml           # Services definition
├── Dockerfile.vault              # Custom Vault image
├── Taskfile.yml                  # Task automation
├── init-and-generate-unseal.sh   # Cluster initialization
├── auto-unseal-monitor.sh        # Monitoring script
├── vault-1/
│   ├── config/
│   │   ├── vault.hcl            # Vault configuration
│   │   └── unseal.sh            # Auto-generated unseal script
│   └── data/                     # Raft data storage
├── vault-2/                      # (same structure)
└── vault-3/                      # (same structure)
```

---

## Step 1: Docker Compose Configuration

Let's start with the `docker-compose.yaml`. This file orchestrates three Vault nodes:

```yaml
version: '3.8'

networks:
  vault_net:
    driver: bridge

services:
  vault-1:
    image: vaultdockercluster:1.20
    restart: unless-stopped
    volumes:
      - ./vault-1/config:/vault/config
      - ./vault-1/data:/vault/data
    cap_add:
      - IPC_LOCK                    # Required for mlock
    entrypoint:
      - vault
      - server
      - -config=/vault/config/vault.hcl
    ulimits:
      memlock: -1                   # Unlimited memory lock
      nofile:
        soft: 65535
        hard: 65535
    networks:
      - vault_net
    healthcheck:
      test: ["CMD", "vault", "status", "-tls-skip-verify"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          cpus: '1'
          memory: 1G

  # vault-2 and vault-3 use the same configuration...
```

**Key Configuration Points:**

| Setting | Purpose |
|---------|---------|
| `IPC_LOCK` | Allows Vault to lock memory pages (prevents swapping secrets to disk) |
| `memlock: -1` | Unlimited memory lock for all processes |
| `healthcheck` | Detects node failures automatically |
| `ulimits` | Handles many concurrent connections |
| `networks` | Isolated network for inter-node communication |

---

## Step 2: Vault Configuration (HCL)

Each node has its own `vault.hcl` configuration:

```hcl
storage "raft" {
  path    = "/vault/data"
  node_id = "vault-1"
}

listener "tcp" {
  address            = "0.0.0.0:8200"
  cluster_address    = "0.0.0.0:8201"
  tls_disable        = true              # Enable TLS in production!
}

api_addr     = "http://vault-1:8200"
cluster_addr = "http://vault-1:8201"

ui = true                                 # Enable web UI
disable_mlock = true                      # Adjust based on your needs
```

**Raft vs Other Backends:**

| Aspect | Raft | Consul | S3 |
|--------|------|--------|-----|
| **Setup Complexity** | Simple | Complex | Simple |
| **Dependencies** | None | Consul cluster needed | AWS account |
| **Cost** | Free | Free (self-hosted) | $ per API call |
| **Performance** | Excellent | Good | Slower |
| **Best For** | Self-hosted HA | Enterprise | AWS-native |

---

## Step 3: Automated Setup with Taskfile

The `Taskfile.yml` automates common operations:

```yaml
version: '3'

vars:
  VAULT_ADDR: 'http://127.0.0.1:8200'
  KEY_SHARES: 5
  KEY_THRESHOLD: 3

tasks:
  bootstrap:
    desc: Complete setup from scratch
    cmds:
      - task: up
      - task: init
      - task: unseal-all
      - task: join-vault-2
      - task: join-vault-3

  up:
    desc: Start the Vault cluster
    cmds:
      - docker-compose up -d

  down:
    desc: Stop the Vault cluster
    cmds:
      - docker-compose down

  init:
    desc: Initialize vault-1
    cmds:
      - ./init-and-generate-unseal.sh

  unseal-all:
    desc: Unseal all nodes
    cmds:
      - task: unseal-vault-1
      - task: unseal-vault-2
      - task: unseal-vault-3
```

Usage is straightforward:

```bash
# Start everything
task bootstrap

# Or step by step
task up
task init
task unseal-all
task join-vault-2
task join-vault-3

# Check status
docker-compose ps
```

---

## Step 4: Initialization and Unsealing

The initialization script (`init-and-generate-unseal.sh`) handles the critical setup:

```bash
#!/bin/bash
set -e

echo "🔐 Initializing Vault Cluster..."

# Wait for vault-1 to be ready
while [ $attempt -lt $max_attempts ]; do
    status=$(docker-compose exec -T vault-1 sh -c \
      "vault status -format=json 2>&1" || true)
    
    if echo "$status" | jq -e . >/dev/null 2>&1; then
        initialized=$(echo "$status" | jq -r '.initialized // false')
        
        if [ "$initialized" = "false" ]; then
            echo "✅ Vault is ready for initialization"
            break
        fi
    fi
    attempt=$((attempt + 1))
    sleep 2
done

# Initialize and capture credentials
INIT_OUTPUT=$(docker-compose exec -T vault-1 sh -c \
  "vault operator init -key-shares=5 -key-threshold=3 -format=json")

# Extract and save credentials
UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

# Save to file with timestamp
BACKUP_FILE="vault-credentials-$(date +%Y%m%d-%H%M%S).md"
cat > "$BACKUP_FILE" << EOF
Root Token: $ROOT_TOKEN
Unseal Keys: ...
EOF

echo "✅ Credentials saved to: $BACKUP_FILE"
```

**Important Security Notes:**

⚠️ **Critical:** Store the root token and unseal keys safely:
- Save them in a password manager
- Never commit them to version control
- Consider using Vault's auto-unseal with KMS (AWS, GCP, Azure)

---

## Step 5: Building the Docker Image

A minimal `Dockerfile.vault`:

```dockerfile
FROM hashicorp/vault:1.20
ENV TZ=Europe/Istanbul
```

Build it with:

```bash
docker build -f Dockerfile.vault -t vaultdockercluster:1.20 .
```

---

## Step 6: Raft Cluster Formation

After initializing vault-1, join the other nodes:

```bash
# Join vault-2 to the cluster
docker-compose exec vault-2 sh -c \
  "vault operator raft join http://vault-1:8200"

# Join vault-3 to the cluster
docker-compose exec vault-3 sh -c \
  "vault operator raft join http://vault-1:8200"

# Verify cluster status
docker-compose exec vault-1 vault operator raft list-peers
```

Expected output:
```
Node ID    Address            State       Voter
------     -------            -----       -----
vault-1    vault-1:8201       leader      true
vault-2    vault-2:8201       follower    true
vault-3    vault-3:8201       follower    true
```

---

## Complete Workflow: From Zero to Hero

Here's the complete startup sequence:

```bash
# 1. Start the containers
task up

# 2. Watch the logs
docker-compose logs -f vault-1

# 3. Initialize the cluster
task init

# Save the credentials somewhere safe!

# 4. Unseal all nodes
task unseal-all

# 5. Join nodes 2 and 3 to the cluster
task join-vault-2
task join-vault-3

# 6. Verify the cluster
docker-compose exec vault-1 vault operator raft list-peers

# 7. Access the UI
open http://localhost:8200/ui
```

---

## Testing Your Cluster

### Test 1: High Availability

Kill the leader node and watch the cluster recover:

```bash
# Kill vault-1 (the leader)
docker-compose kill vault-1

# Check who's the new leader
docker-compose exec vault-2 vault operator raft list-peers

# Bring it back
docker-compose restart vault-1

# Verify recovery
docker-compose ps
```

### Test 2: Secret Storage

Store and retrieve a secret:

```bash
# Login
export VAULT_TOKEN="your-root-token"
export VAULT_ADDR="http://localhost:8200"

# Create a secret
vault kv put secret/my-app/database \
  username=admin \
  password=super-secret-password

# Retrieve it
vault kv get secret/my-app/database

# Read it via API
curl -H "X-Vault-Token: $VAULT_TOKEN" \
  http://localhost:8200/v1/secret/data/my-app/database
```

### Test 3: Encryption as a Service

```bash
# Enable transit engine
vault secrets enable transit

# Create an encryption key
vault write -f transit/keys/my-key

# Encrypt data
vault write transit/encrypt/my-key plaintext=@data.txt

# Decrypt it
vault write transit/decrypt/my-key ciphertext=vault:v1:...
```

---

## Monitoring and Maintenance

### Check Cluster Health

```bash
# Status of all nodes
docker-compose exec vault-1 vault status

# Raft peer status
docker-compose exec vault-1 vault operator raft list-peers

# Audit logs
docker-compose logs vault-1 | grep ERROR

# System metrics
docker-compose stats
```

### Common Issues and Solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| Node won't join | Already part of a cluster | Run `task reset` and `task bootstrap` |
| Sealed after crash | No auto-unseal configured | Run `task unseal-vault-1` |
| Connection refused | Node not running | Check with `docker-compose ps` |
| Memory locked | mlock issues | Check `ulimits` and `IPC_LOCK` capability |

---

## Production Considerations

### 1. Enable TLS/HTTPS

```hcl
listener "tcp" {
  address            = "0.0.0.0:8200"
  tls_cert_file      = "/vault/config/cert.pem"
  tls_key_file       = "/vault/config/key.pem"
}
```

### 2. Enable Audit Logging

```hcl
audit {
  file {
    path = "/vault/logs/audit.log"
  }
}
```

### 3. Configure Storage Snapshots

```bash
# Backup Raft data
vault operator raft snapshot save vault-backup.snap

# Restore from snapshot
vault operator raft snapshot restore -force vault-backup.snap
```

### 4. Set Resource Limits

```yaml
deploy:
  resources:
    limits:
      cpus: '2'
      memory: 4G
    reservations:
      cpus: '1'
      memory: 2G
```

---

## Scaling Considerations

### Adding More Nodes

```bash
# Copy vault-1 directory structure
cp -r vault-1 vault-4

# Update vault-4/config/vault.hcl (change node_id)
sed -i 's/vault-1/vault-4/g' vault-4/config/vault.hcl

# Add to docker-compose.yaml and run
docker-compose up -d vault-4
```

### Load Balancing

```nginx
upstream vault {
    server vault-1:8200;
    server vault-2:8200;
    server vault-3:8200;
}

server {
    listen 80;
    location / {
        proxy_pass http://vault;
    }
}
```

---

## Advanced: Disaster Recovery

### Scenario: Complete Cluster Failure

```bash
# 1. Reset everything
task reset

# 2. Restore from backup
vault operator raft snapshot restore -force vault-backup.snap

# 3. Bring cluster back up
task bootstrap
```

### Scenario: Corrupted Raft State

```bash
# 1. Stop all nodes
task down

# 2. Clean data directories
rm -rf vault-*/data/raft/*

# 3. Restore from known-good backup
# Copy backed-up raft directory to all nodes

# 4. Start nodes
task up
```

---

## Conclusion

You now have a production-ready, highly-available Vault cluster with:

✅ **Three-node Raft cluster** for high availability  
✅ **Automated deployment** via Docker Compose  
✅ **Task automation** for common operations  
✅ **Auto-unsealing** capability  
✅ **Health monitoring** and failure detection  
✅ **Scalable architecture** ready for growth  

### Resources

- [Official Vault Documentation](https://www.vaultproject.io/docs)
- [Raft Storage Backend Guide](https://www.vaultproject.io/docs/configuration/storage/raft)
- [Production Hardening Checklist](https://www.vaultproject.io/docs/concepts/integrated-storage)
- [Auto-Unseal Configuration](https://www.vaultproject.io/docs/configuration/seal)

---

## About the Author

This article demonstrates a practical approach to secrets management using open-source tools. For production deployments, consider consulting with security specialists to ensure compliance with your organization's security requirements.

**Have questions?** Share them in the comments below!

---

*GitHub Repository: [vault-docker-cluster](https://github.com/isennkubilay/vault-docker-cluster)*
