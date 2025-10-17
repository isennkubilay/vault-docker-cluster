#!/bin/sh
set -e

# Auto-unseal monitor for Vault cluster
# This script continuously monitors vault instances and unseals them if they become sealed

VAULT_INSTANCES="vault-1 vault-2 vault-3"
CONFIG_PATHS="/vault/config /vault/config /vault/config"
CHECK_INTERVAL=30
MAX_RETRIES=3

echo "🔐 Vault Auto-Unseal Monitor Started"
echo "Monitor interval: ${CHECK_INTERVAL}s"
echo ""

# Function to check if vault is sealed
is_sealed() {
    local vault_name=$1
    local vault_host=$2
    
    export VAULT_ADDR="http://$vault_host:8200"
    status=$(vault status -format=json 2>&1 | grep -o '"sealed":[^,}]*' || echo '"sealed":true')
    
    if echo "$status" | grep -q "false"; then
        return 1  # Not sealed
    else
        return 0  # Sealed
    fi
}

# Function to unseal vault
unseal_vault() {
    local vault_name=$1
    local vault_host=$2
    local config_path=$3
    
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] 🔓 Unsealing $vault_name..."
    
    if [ ! -f "$config_path/unseal.sh" ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  Unseal script not found at $config_path/unseal.sh"
        return 1
    fi
    
    # Extract unseal keys
    UNSEAL_KEY_1=$(grep "vault operator unseal" "$config_path/unseal.sh" | head -1 | awk '{print $NF}')
    UNSEAL_KEY_2=$(grep "vault operator unseal" "$config_path/unseal.sh" | head -2 | tail -1 | awk '{print $NF}')
    UNSEAL_KEY_3=$(grep "vault operator unseal" "$config_path/unseal.sh" | head -3 | tail -1 | awk '{print $NF}')
    
    if [ -z "$UNSEAL_KEY_1" ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ❌ Could not extract unseal keys"
        return 1
    fi
    
    # Unseal
    export VAULT_ADDR="http://$vault_host:8200"
    
    retry_count=0
    while [ $retry_count -lt $MAX_RETRIES ]; do
        result=$(vault operator unseal "$UNSEAL_KEY_1" 2>&1 && vault operator unseal "$UNSEAL_KEY_2" 2>&1 && vault operator unseal "$UNSEAL_KEY_3" 2>&1 || true)
        
        if echo "$result" | grep -q "false"; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $vault_name unsealed successfully"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $MAX_RETRIES ]; then
            sleep 5
        fi
    done
    
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  Failed to unseal $vault_name after $MAX_RETRIES attempts"
    return 1
}

# Main monitoring loop
while true; do
    for instance in $VAULT_INSTANCES; do
        vault_host=$instance
        
        # Check if vault is reachable and sealed
        if is_sealed "$instance" "$vault_host" 2>/dev/null; then
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  $instance is SEALED - attempting to unseal..."
            
            case $instance in
                vault-1) unseal_vault "$instance" "$vault_host" "/vault/config" ;;
                vault-2) unseal_vault "$instance" "$vault_host" "/vault/config-2" ;;
                vault-3) unseal_vault "$instance" "$vault_host" "/vault/config-3" ;;
            esac
        else
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] ✓ $instance is unsealed"
        fi
    done
    
    sleep $CHECK_INTERVAL
done
