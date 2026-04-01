#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# setup-runner-vm.sh
#
# One-time provisioning script for a self-hosted GitHub Actions runner VM
# with user-assigned managed identity. This VM simulates an on-premises agent
# for the Private AKS PoC.
#
# Prerequisites:
#   - Azure CLI installed and logged in with Owner or User Access Administrator
#   - Subscription selected (az account set -s <subscription-id>)
#
# Usage:
#   chmod +x scripts/setup-runner-vm.sh
#   ./scripts/setup-runner-vm.sh
#
# Environment variables (all optional, defaults shown):
#   LOCATION            - Azure region          (default: canadacentral)
#   RESOURCE_GROUP      - Resource group name   (default: rg-aks-poc-runner)
#   VM_NAME             - VM name               (default: vm-aks-poc-runner)
#   MI_NAME             - Managed identity name (default: mi-aks-poc-deployer)
#   VM_SIZE             - VM SKU                (default: Standard_B2s)
#   VM_IMAGE            - VM OS image           (default: Ubuntu2204)
#   ADMIN_USERNAME      - VM admin user         (default: azureuser)
###############################################################################

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LOCATION="${LOCATION:-canadacentral}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-poc-runner}"
VM_NAME="${VM_NAME:-vm-aks-poc-runner}"
MI_NAME="${MI_NAME:-mi-aks-poc-deployer}"
VM_SIZE="${VM_SIZE:-Standard_B2s}"
VM_IMAGE="${VM_IMAGE:-Ubuntu2204}"
ADMIN_USERNAME="${ADMIN_USERNAME:-azureuser}"

REPO_URL="https://github.com/devopsabcs-engineering/aks-private-deployment"

# ---------------------------------------------------------------------------
# Determine subscription and tenant from current Azure CLI context
# ---------------------------------------------------------------------------
echo "=== Resolving Azure context ==="
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "Subscription : $SUBSCRIPTION_ID"
echo "Tenant       : $TENANT_ID"
echo "Location     : $LOCATION"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Create resource group
# ---------------------------------------------------------------------------
echo "=== Step 1: Creating resource group '$RESOURCE_GROUP' ==="
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags purpose=aks-poc component=runner created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --output none
echo "Resource group created."
echo ""

# ---------------------------------------------------------------------------
# Step 2: Create user-assigned managed identity
# ---------------------------------------------------------------------------
echo "=== Step 2: Creating managed identity '$MI_NAME' ==="
az identity create \
  --name "$MI_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags purpose=aks-poc \
  --output none

MI_CLIENT_ID="$(az identity show \
  --name "$MI_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query clientId -o tsv)"

MI_PRINCIPAL_ID="$(az identity show \
  --name "$MI_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query principalId -o tsv)"

MI_RESOURCE_ID="$(az identity show \
  --name "$MI_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)"

echo "Managed identity created."
echo "  Client ID    : $MI_CLIENT_ID"
echo "  Principal ID : $MI_PRINCIPAL_ID"
echo ""

# ---------------------------------------------------------------------------
# Step 3: Assign RBAC roles to the managed identity
# ---------------------------------------------------------------------------
echo "=== Step 3: Assigning RBAC roles ==="

echo "  Assigning 'Contributor' at subscription scope..."
az role assignment create \
  --assignee-object-id "$MI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID" \
  --output none

echo "  Assigning 'Monitoring Reader' at subscription scope..."
az role assignment create \
  --assignee-object-id "$MI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Monitoring Reader" \
  --scope "/subscriptions/$SUBSCRIPTION_ID" \
  --output none

echo "RBAC roles assigned."
echo ""

# ---------------------------------------------------------------------------
# Step 4: Create cloud-init script for VM provisioning
# ---------------------------------------------------------------------------
echo "=== Step 4: Preparing cloud-init configuration ==="

CLOUD_INIT=$(cat <<'CLOUD_INIT_EOF'
#cloud-config
package_update: true
package_upgrade: true
packages:
  - curl
  - jq
  - unzip
  - apt-transport-https
  - ca-certificates
  - gnupg
  - lsb-release

runcmd:
  # Install Azure CLI
  - curl -sL https://aka.ms/InstallAzureCLIDeb | bash

  # Create a directory for the GitHub Actions runner
  - mkdir -p /home/azureuser/actions-runner
  - chown azureuser:azureuser /home/azureuser/actions-runner

  # Download the latest GitHub Actions runner
  - |
    RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')
    curl -sL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
      -o /tmp/actions-runner.tar.gz
    tar xzf /tmp/actions-runner.tar.gz -C /home/azureuser/actions-runner
    chown -R azureuser:azureuser /home/azureuser/actions-runner
    rm -f /tmp/actions-runner.tar.gz

  # Install runner dependencies
  - /home/azureuser/actions-runner/bin/installdependencies.sh
CLOUD_INIT_EOF
)

echo "Cloud-init configuration prepared."
echo ""

# ---------------------------------------------------------------------------
# Step 5: Create the runner VM
# ---------------------------------------------------------------------------
echo "=== Step 5: Creating VM '$VM_NAME' ($VM_SIZE, $VM_IMAGE) ==="

az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --image "$VM_IMAGE" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USERNAME" \
  --generate-ssh-keys \
  --assign-identity "$MI_RESOURCE_ID" \
  --tags purpose=aks-poc component=runner \
  --custom-data <(echo "$CLOUD_INIT") \
  --output none

VM_PUBLIC_IP="$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --show-details \
  --query publicIps -o tsv)"

echo "VM created."
echo "  Public IP : $VM_PUBLIC_IP"
echo ""

# ---------------------------------------------------------------------------
# Summary: Next steps
# ---------------------------------------------------------------------------
echo "==========================================================================="
echo " SETUP COMPLETE"
echo "==========================================================================="
echo ""
echo "--- GitHub Secrets (add to repository settings) ---"
echo ""
echo "  Repository : $REPO_URL"
echo "  Settings   : $REPO_URL/settings/secrets/actions"
echo ""
echo "  AZURE_CLIENT_ID       : $MI_CLIENT_ID"
echo "  AZURE_TENANT_ID       : $TENANT_ID"
echo "  AZURE_SUBSCRIPTION_ID : $SUBSCRIPTION_ID"
echo ""
echo "--- SSH into the runner VM ---"
echo ""
echo "  ssh $ADMIN_USERNAME@$VM_PUBLIC_IP"
echo ""
echo "--- Register the GitHub Actions runner ---"
echo ""
echo "  1. Go to $REPO_URL/settings/actions/runners/new"
echo "  2. Copy the registration token"
echo "  3. SSH into the VM and run:"
echo ""
echo "     cd ~/actions-runner"
echo "     ./config.sh --url $REPO_URL --token <REGISTRATION_TOKEN>"
echo "     sudo ./svc.sh install"
echo "     sudo ./svc.sh start"
echo ""
echo "--- Verify managed identity works on the VM ---"
echo ""
echo "  az login --identity --username $MI_CLIENT_ID"
echo "  az account show"
echo ""
echo "==========================================================================="
