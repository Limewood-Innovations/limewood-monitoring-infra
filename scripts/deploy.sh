#!/usr/bin/env bash
# Deploy the limewood-monitoring-infra Bicep stack.
# Usage:  ./scripts/deploy.sh <env>          # env in {dev, stage, prod}
#         ./scripts/deploy.sh <env> --whatif # dry-run (preview only)
#
# Requires:  az CLI logged in to the Alpenland tenant
#            OPSGENIE_WEBHOOK_URL env var set
set -euo pipefail

env="${1:-}"
mode="${2:-create}"

if [[ -z "${env}" || ! "${env}" =~ ^(dev|stage|prod)$ ]]; then
    echo "usage: $0 <dev|stage|prod> [--whatif]" >&2
    exit 1
fi

: "${OPSGENIE_WEBHOOK_URL:?OPSGENIE_WEBHOOK_URL must be set}"
: "${PG_ADMIN_PASSWORD:?PG_ADMIN_PASSWORD must be set (Postgres SQL admin)}"
: "${PG_AAD_ADMIN_OBJECT_ID:?PG_AAD_ADMIN_OBJECT_ID must be set (the AAD principal that becomes Postgres AAD admin)}"
: "${PG_AAD_ADMIN_NAME:?PG_AAD_ADMIN_NAME must be set (display name of the AAD admin)}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
template="${repo_root}/bicep/main.bicep"
params="${repo_root}/bicep/parameters/${env}.bicepparam"
location="westeurope"
deployment_name="alpenland-obs-${env}-$(date +%Y%m%d%H%M%S)"

echo "→ Deploying ${env} (mode=${mode}) using ${params}"

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
echo "Paste APPINSIGHTS_CONNECTION_STRING into the consuming tool's .env"
echo "(e.g. doc_search/.env, hermes/.env, …)."
