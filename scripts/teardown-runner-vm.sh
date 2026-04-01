#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# teardown-runner-vm.sh
#
# Deletes the runner VM resource group and all resources within it.
# Use this when the PoC is complete to avoid ongoing costs.
#
# Usage:
#   ./scripts/teardown-runner-vm.sh          # prompts for confirmation
#   ./scripts/teardown-runner-vm.sh --yes    # skips confirmation prompt
#
# Environment variables (optional):
#   RESOURCE_GROUP  - Resource group to delete (default: rg-aks-poc-runner)
###############################################################################

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-poc-runner}"
REPO_URL="https://github.com/devopsabcs-engineering/aks-private-deployment"
AUTO_CONFIRM=false

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --yes|-y)
      AUTO_CONFIRM=true
      ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: $0 [--yes]"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Verify the resource group exists
# ---------------------------------------------------------------------------
echo "=== Checking resource group '$RESOURCE_GROUP' ==="

if ! az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; then
  echo "Resource group '$RESOURCE_GROUP' does not exist. Nothing to delete."
  exit 0
fi

echo "Resource group '$RESOURCE_GROUP' found."
echo ""

# ---------------------------------------------------------------------------
# Confirm deletion
# ---------------------------------------------------------------------------
if [ "$AUTO_CONFIRM" = false ]; then
  echo "WARNING: This will permanently delete resource group '$RESOURCE_GROUP'"
  echo "         and ALL resources within it (VM, managed identity, disks, NICs, etc.)."
  echo ""
  read -r -p "Are you sure you want to proceed? (y/N): " response
  case "$response" in
    [yY][eE][sS]|[yY])
      echo ""
      ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Delete the resource group
# ---------------------------------------------------------------------------
echo "=== Deleting resource group '$RESOURCE_GROUP' ==="
az group delete \
  --name "$RESOURCE_GROUP" \
  --yes \
  --no-wait

echo "Resource group deletion initiated (running in background)."
echo ""

# ---------------------------------------------------------------------------
# Remind about GitHub runner deregistration
# ---------------------------------------------------------------------------
echo "==========================================================================="
echo " IMPORTANT: Remove the GitHub Actions runner"
echo "==========================================================================="
echo ""
echo "  The self-hosted runner must also be removed from the repository:"
echo ""
echo "  1. Go to $REPO_URL/settings/actions/runners"
echo "  2. Find the runner associated with the deleted VM"
echo "  3. Click the '...' menu and select 'Remove'"
echo ""
echo "  If the runner VM was configured as a service, it will appear offline"
echo "  and can be force-removed from the repository settings."
echo ""
echo "==========================================================================="
