#!/usr/bin/env bash
# =============================================================================
# deploy-private-aks.sh — Create a Private AKS Cluster with Managed Identity
# =============================================================================
#
# PURPOSE:
#   This script creates a private AKS cluster using managed identity
#   authentication. It is designed to run from any Azure VM that has a
#   managed identity assigned — no service principal secrets required.
#
# AUTHENTICATION FLOW COMPARISON:
#
#   SERVICE PRINCIPAL FLOW (PROBLEMATIC WITH CONDITIONAL ACCESS):
#     Runner VM → az login --service-principal → login.microsoftonline.com
#       (from Runner IP — OK if IP is in CA named location)
#     Runner VM → az aks create → ARM → AKS RP → login.microsoftonline.com
#       (from Azure datacenter IP — BLOCKED by CA location policy)
#
#   MANAGED IDENTITY FLOW (RECOMMENDED):
#     Runner VM → az login --identity → IMDS 169.254.169.254
#       (internal call, no CA evaluation)
#     Runner VM → az aks create → ARM → AKS RP → Azure fabric token
#       (internal call, not evaluated by CA)
#
#   Managed identities are explicitly excluded from Conditional Access
#   workload identity policies. Token acquisition happens within the
#   Azure fabric via IMDS, so location-based CA policies never apply.
#
# USAGE:
#   # Run with defaults
#   ./deploy-private-aks.sh
#
#   # Override parameters via environment variables
#   RESOURCE_GROUP=my-rg CLUSTER_NAME=my-aks LOCATION=eastus ./deploy-private-aks.sh
#
# PREREQUISITES:
#   - Azure CLI installed (v2.28.0+)
#   - VM has a managed identity assigned
#   - Managed identity has Contributor role on the target subscription/RG
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Parameters — override via environment variables; sensible defaults provided
# ---------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-poc}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-poc}"
LOCATION="${LOCATION:-canadacentral}"
VNET_NAME="${VNET_NAME:-vnet-aks-poc}"
SUBNET_NAME="${SUBNET_NAME:-subnet-aks}"

VNET_CIDR="10.224.0.0/16"
SUBNET_CIDR="10.224.0.0/24"

echo "============================================================"
echo "Private AKS Deployment — Managed Identity"
echo "============================================================"
echo "Resource Group : $RESOURCE_GROUP"
echo "Cluster Name   : $CLUSTER_NAME"
echo "Location       : $LOCATION"
echo "VNet           : $VNET_NAME ($VNET_CIDR)"
echo "Subnet         : $SUBNET_NAME ($SUBNET_CIDR)"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Authenticate using the VM's managed identity
# ---------------------------------------------------------------------------
# az login --identity acquires a token from the Instance Metadata Service
# (IMDS) at 169.254.169.254. This is an internal Azure fabric call that
# does NOT go through login.microsoftonline.com, so Conditional Access
# location policies are never evaluated.
echo ">>> Step 1: Logging in with managed identity..."
az login --identity
echo "Logged in successfully via managed identity."
echo ""

# ---------------------------------------------------------------------------
# Step 2: Create the resource group with tracking tags
# ---------------------------------------------------------------------------
# Tags help the safety-net cleanup workflow identify PoC resource groups.
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo ">>> Step 2: Creating resource group '$RESOURCE_GROUP'..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags purpose=aks-poc created="$TIMESTAMP"
echo "Resource group created."
echo ""

# ---------------------------------------------------------------------------
# Step 3: Create the Virtual Network and Subnet
# ---------------------------------------------------------------------------
# The AKS cluster needs a subnet to deploy nodes into when using
# the Azure CNI network plugin.
echo ">>> Step 3: Creating VNet '$VNET_NAME' and subnet '$SUBNET_NAME'..."
az network vnet create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VNET_NAME" \
  --address-prefixes "$VNET_CIDR" \
  --subnet-name "$SUBNET_NAME" \
  --subnet-prefixes "$SUBNET_CIDR"
echo "VNet and subnet created."
echo ""

# ---------------------------------------------------------------------------
# Step 4: Retrieve the subnet resource ID for AKS
# ---------------------------------------------------------------------------
echo ">>> Step 4: Retrieving subnet resource ID..."
SUBNET_ID="$(az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" \
  --query id \
  --output tsv)"
echo "Subnet ID: $SUBNET_ID"
echo ""

# ---------------------------------------------------------------------------
# Step 5: Create the private AKS cluster with managed identity
# ---------------------------------------------------------------------------
# --enable-private-cluster : API server is accessible only via private endpoint
# --enable-managed-identity: AKS control plane uses managed identity (not SP)
#                            → tokens acquired via Azure fabric, CA-exempt
# --network-plugin azure   : Azure CNI — pods get IPs from the subnet
# --node-vm-size Standard_B2s : Cost-effective burstable VM for PoC
# --tier free               : No SLA, minimizes cost for testing
echo ">>> Step 5: Creating private AKS cluster '$CLUSTER_NAME'..."
echo "    (This may take 5-10 minutes)"
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --node-count 1 \
  --node-vm-size Standard_B2s \
  --network-plugin azure \
  --vnet-subnet-id "$SUBNET_ID" \
  --enable-private-cluster \
  --enable-managed-identity \
  --generate-ssh-keys \
  --tier free
echo "AKS cluster created successfully."
echo ""

# ---------------------------------------------------------------------------
# Step 6: Display cluster information
# ---------------------------------------------------------------------------
echo ">>> Step 6: Retrieving cluster details..."

# The private FQDN is the internal DNS name for the API server,
# accessible only from within the VNet (or peered VNets).
PRIVATE_FQDN="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query "privateFqdn" \
  --output tsv)"

# The cluster's managed identity — this is the identity the AKS control
# plane uses for infrastructure operations (Contributor on node RG).
MI_PRINCIPAL_ID="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query "identity.principalId" \
  --output tsv)"

MI_TYPE="$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query "identity.type" \
  --output tsv)"

echo ""
echo "============================================================"
echo "Deployment Complete"
echo "============================================================"
echo "Private FQDN     : $PRIVATE_FQDN"
echo "Identity Type     : $MI_TYPE"
echo "Identity Principal: $MI_PRINCIPAL_ID"
echo "============================================================"
echo ""
echo "Next steps:"
echo "  1. Ensure DNS resolves the private FQDN from within the VNet"
echo "  2. Run 'az aks get-credentials' to fetch kubeconfig"
echo "  3. Use 'kubectl' from within the VNet to interact with the cluster"
echo "  4. Run scripts/log-ips.sh to verify IP perimeter"
