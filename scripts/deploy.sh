#!/usr/bin/env bash
# Deploy the limewood-monitoring-infra Bicep stack.
#
# Single shared deployment — one resource group + one of each component for
# all envs (dev/stage/prod). See README "Bring Your Own Postgres" for the
# DB setup on Alpenland's existing Postgres server.
#
# Usage:
#   ./scripts/deploy.sh            # deploy
#   ./scripts/deploy.sh --whatif   # dry-run, show diff only
#
# Required env vars (always):
#   OPSGENIE_WEBHOOK_URL    — Azure Monitor → OpsGenie webhook
#
# Required env vars only when provisionPostgres=true (default false):
#   PG_ADMIN_PASSWORD       — generate with `openssl rand -base64 32`
#   PG_AAD_ADMIN_OBJECT_ID  — `az ad signed-in-user show --query id -o tsv`
#   PG_AAD_ADMIN_NAME       — display name (cosmetic)

set -euo pipefail

mode="${1:-create}"

: "${OPSGENIE_WEBHOOK_URL:?OPSGENIE_WEBHOOK_URL must be set}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
template="${repo_root}/bicep/main.bicep"
params="${repo_root}/bicep/parameters/main.bicepparam"
location="westeurope"
deployment_name="alpenland-obs-$(date +%Y%m%d%H%M%S)"

# When provisionPostgres = true (the default), Postgres needs admin credentials
# at deploy time. Read the bicepparam to detect this so we fail fast with a
# helpful message instead of letting Bicep complain mid-deploy.
if grep -qE '^param +provisionPostgres += +true\b' "${params}"; then
    : "${PG_ADMIN_PASSWORD:?PG_ADMIN_PASSWORD must be set when provisioning Postgres (openssl rand -base64 32)}"
    : "${PG_AAD_ADMIN_OBJECT_ID:?PG_AAD_ADMIN_OBJECT_ID must be set (az ad signed-in-user show --query id -o tsv)}"
    : "${PG_AAD_ADMIN_NAME:?PG_AAD_ADMIN_NAME must be set (display name of the AAD admin)}"
fi

echo "→ Deploying observability stack (mode=${mode})"
echo "  template: ${template}"
echo "  params:   ${params}"

if [[ "${mode}" == "--whatif" ]]; then
    az deployment sub what-if \
        --location "${location}" \
        --name "${deployment_name}" \
        --template-file "${template}" \
        --parameters "${params}"
    exit 0
fi

az deployment sub create \
    --location "${location}" \
    --name "${deployment_name}" \
    --template-file "${template}" \
    --parameters "${params}" \
    --output json > "/tmp/${deployment_name}.json"

echo
echo "✓ Deployment ${deployment_name} succeeded. Outputs:"
echo
jq -r '
    .properties.outputs |
    to_entries[] |
    "\(.key | ascii_upcase)=\(.value.value)"
' "/tmp/${deployment_name}.json"

echo
echo "Next steps:"
echo "  1. Stash APPINSIGHTS_CONNECTION_STRING in the shared KeyVault as"
echo "     secret 'appinsights-connection-string'."
echo "  2. If POSTGRES_PROVISIONED = false, run the BYO-Postgres setup from"
echo "     the README to create the observability DB + obs_writer role on"
echo "     your existing Postgres, then stash the URL in KeyVault as"
echo "     'observability-sql-url'."
echo "  3. Each tool (doc_search, hermes, …) sets the same two ENV vars in"
echo "     dev/stage/prod — only APP_ENV differs."
