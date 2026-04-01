#!/usr/bin/env bash
# =============================================================================
# log-ips.sh — IP Logging and Verification Utility
# =============================================================================
#
# PURPOSE:
#   Queries three data sources to verify that managed identity traffic stays
#   within the expected network perimeter during AKS deployment:
#     1. Runner/VM outbound IP (via ifconfig.me)
#     2. Azure Activity Log ARM operation caller IPs
#     3. Entra ID Sign-In Logs (requires P1/P2 license — graceful failure)
#
# USAGE:
#   # Run with defaults (uses current resource group and last hour)
#   RESOURCE_GROUP=rg-aks-poc ./log-ips.sh
#
#   # Specify a custom start time and identity client ID
#   RESOURCE_GROUP=rg-aks-poc \
#   START_TIME=2026-04-01T10:00:00Z \
#   IDENTITY_CLIENT_ID=<client-id> \
#   ./log-ips.sh
#
# PREREQUISITES:
#   - Azure CLI installed and logged in
#   - Monitoring Reader role on the subscription (for Activity Log)
#   - Optionally: AuditLog.Read.All Graph API permission (for sign-in logs)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Parameters — override via environment variables
# ---------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-poc}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"
IDENTITY_CLIENT_ID="${IDENTITY_CLIENT_ID:-}"

# Default START_TIME to 1 hour ago if not provided
if [ -z "${START_TIME:-}" ]; then
  # Use date -u for UTC; works on GNU date (Linux)
  START_TIME="$(date -u -d '1 hour ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")"
  if [ -z "$START_TIME" ]; then
    echo "WARNING: Could not compute default START_TIME. Please set START_TIME manually."
    START_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fi
fi

echo "============================================================"
echo "IP Logging and Verification"
echo "============================================================"
echo "Resource Group   : $RESOURCE_GROUP"
echo "Start Time       : $START_TIME"
echo "Wait Seconds     : $WAIT_SECONDS"
echo "Identity Client  : ${IDENTITY_CLIENT_ID:-<not specified>}"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Section 1: Runner/VM Outbound IP
# ---------------------------------------------------------------------------
echo "=== Runner/VM Outbound IP ==="
RUNNER_IP="$(curl -s --max-time 10 ifconfig.me || echo "UNAVAILABLE")"
echo "Public IP: $RUNNER_IP"
echo ""

# ---------------------------------------------------------------------------
# Section 2: Wait for Activity Log propagation
# ---------------------------------------------------------------------------
# Azure Activity Log entries can take a few minutes to appear after the
# operation completes. This wait ensures we capture recent operations.
if [ "$WAIT_SECONDS" -gt 0 ]; then
  echo "Waiting ${WAIT_SECONDS}s for Activity Log propagation..."
  sleep "$WAIT_SECONDS"
  echo ""
fi

# ---------------------------------------------------------------------------
# Section 3: Azure Activity Log — ARM Operation Caller IPs
# ---------------------------------------------------------------------------
echo "=== Azure Activity Log — ARM Operation Caller IPs ==="
echo ""

# Query Activity Log for ContainerService and Network operations.
# JMESPath extracts the fields we need: operation name, caller identity,
# the HTTP request client IP, status, and timestamp.
ACTIVITY_LOG_JSON="$(az monitor activity-log list \
  --resource-group "$RESOURCE_GROUP" \
  --start-time "$START_TIME" \
  --query "[?contains(resourceType.value, 'Microsoft.ContainerService') || contains(resourceType.value, 'Microsoft.Network')].{operation:operationName.localizedValue, caller:caller, clientIp:httpRequest.clientIpAddress, status:status.value, time:eventTimestamp}" \
  --output json 2>/dev/null || echo "[]")"

# Parse and display the results
ACTIVITY_LOG_COUNT="$(echo "$ACTIVITY_LOG_JSON" | python3 -c "import sys,json; data=json.load(sys.stdin); print(len(data))" 2>/dev/null || echo "0")"

if [ "$ACTIVITY_LOG_COUNT" -eq 0 ]; then
  echo "No Activity Log entries found for the specified time range and resource group."
  echo "This may mean:"
  echo "  - Operations have not propagated to the Activity Log yet (try increasing WAIT_SECONDS)"
  echo "  - No ContainerService or Network operations occurred in this resource group"
  echo ""
else
  # Print a formatted table header
  printf "%-55s | %-25s | %-15s | %-12s | %s\n" "Operation" "Caller" "Client IP" "Status" "Time"
  printf "%-55s-+-%-25s-+-%-15s-+-%-12s-+-%s\n" "-------------------------------------------------------" "-------------------------" "---------------" "------------" "-------------------------"

  # Print each row using python3 for reliable JSON parsing
  echo "$ACTIVITY_LOG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for entry in data:
    op = (entry.get('operation') or 'N/A')[:55]
    caller = (entry.get('caller') or 'N/A')[:25]
    ip = entry.get('clientIp') or 'N/A'
    status = (entry.get('status') or 'N/A')[:12]
    time = (entry.get('time') or 'N/A')[:25]
    print(f'{op:<55} | {caller:<25} | {ip:<15} | {status:<12} | {time}')
"
  echo ""
fi

# Collect unique IPs from Activity Log for the summary
ACTIVITY_IPS="$(echo "$ACTIVITY_LOG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ips = set()
for entry in data:
    ip = entry.get('clientIp')
    if ip:
        ips.add(ip)
for ip in sorted(ips):
    print(ip)
" 2>/dev/null || echo "")"

# ---------------------------------------------------------------------------
# Section 4: Entra ID Sign-In Logs (requires P1/P2)
# ---------------------------------------------------------------------------
echo "=== Entra ID Sign-In Log IPs (requires P1/P2) ==="
echo ""

# Build the Graph API filter for sign-in logs.
# This queries managed identity and service principal sign-ins.
# NOTE: This requires the directory to have Entra ID P1 or P2 licensing
#       and the caller to have AuditLog.Read.All permissions.
GRAPH_FILTER="createdDateTime ge ${START_TIME}"
if [ -n "$IDENTITY_CLIENT_ID" ]; then
  GRAPH_FILTER="${GRAPH_FILTER} and appId eq '${IDENTITY_CLIENT_ID}'"
fi

ENCODED_FILTER="$(python3 -c "import urllib.parse; print(urllib.parse.quote('$GRAPH_FILTER'))" 2>/dev/null || echo "")"

SIGNIN_LOGS=""
SIGNIN_SUCCESS=false

if [ -n "$ENCODED_FILTER" ]; then
  # Attempt to query the Microsoft Graph signIns endpoint.
  # This will fail with 403 or similar if the tenant lacks P1/P2 licensing.
  SIGNIN_LOGS="$(az rest \
    --method GET \
    --url "https://graph.microsoft.com/v1.0/auditLogs/signIns?\$filter=${ENCODED_FILTER}&\$select=ipAddress,appDisplayName,createdDateTime,status&\$top=50" \
    --query "value[].{ip:ipAddress, application:appDisplayName, time:createdDateTime, statusCode:status.errorCode}" \
    --output json 2>/dev/null)" && SIGNIN_SUCCESS=true || SIGNIN_SUCCESS=false
fi

if [ "$SIGNIN_SUCCESS" = true ] && [ -n "$SIGNIN_LOGS" ] && [ "$SIGNIN_LOGS" != "[]" ]; then
  printf "%-15s | %-25s | %-25s | %s\n" "IP" "Application" "Time" "Status"
  printf "%-15s-+-%-25s-+-%-25s-+-%s\n" "---------------" "-------------------------" "-------------------------" "----------"

  echo "$SIGNIN_LOGS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for entry in data:
    ip = (entry.get('ip') or 'N/A')[:15]
    app = (entry.get('application') or 'N/A')[:25]
    time = (entry.get('time') or 'N/A')[:25]
    status = str(entry.get('statusCode', 'N/A'))
    print(f'{ip:<15} | {app:<25} | {time:<25} | {status}')
"
  echo ""
else
  echo "Could not retrieve Entra ID sign-in logs."
  echo "This is expected if the tenant does not have Entra ID P1/P2 licensing,"
  echo "or if the calling identity lacks AuditLog.Read.All permissions."
  echo "This does NOT affect the Activity Log analysis above."
  echo ""
fi

# ---------------------------------------------------------------------------
# Section 5: IP Verification Summary
# ---------------------------------------------------------------------------
echo "=== IP Verification Summary ==="
echo ""
echo "Runner IP: $RUNNER_IP"
echo ""

if [ -z "$ACTIVITY_IPS" ]; then
  echo "Activity Log IPs: (none found — see Activity Log section above)"
else
  MATCHING_IPS=""
  NON_MATCHING_IPS=""

  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    if [ "$ip" = "$RUNNER_IP" ]; then
      MATCHING_IPS="${MATCHING_IPS:+$MATCHING_IPS, }$ip"
    else
      NON_MATCHING_IPS="${NON_MATCHING_IPS:+$NON_MATCHING_IPS, }$ip"
    fi
  done <<< "$ACTIVITY_IPS"

  if [ -n "$MATCHING_IPS" ]; then
    echo "Activity Log IPs matching runner: $MATCHING_IPS (EXPECTED)"
  else
    echo "Activity Log IPs matching runner: (none)"
  fi

  if [ -n "$NON_MATCHING_IPS" ]; then
    echo "Activity Log IPs NOT matching runner: $NON_MATCHING_IPS (INVESTIGATE)"
    echo ""
    echo "NOTE: Non-matching IPs are expected for managed identity scenarios."
    echo "      The AKS RP acquires tokens via Azure fabric (IMDS), and ARM"
    echo "      operations may show Azure datacenter IPs. This is normal and"
    echo "      does NOT indicate a security issue when using managed identity."
  else
    echo "Activity Log IPs NOT matching runner: (none)"
  fi
fi

echo ""
echo "============================================================"
echo "IP logging complete."
echo "============================================================"
