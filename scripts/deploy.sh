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
# Required env vars when provisionPostgres=true (the default):
#   PG_ADMIN_USERNAME       — defaults to 'pgadmin' if unset
#   PG_ADMIN_PASSWORD       — generate with `openssl rand -base64 32`
#
# `setup-postgres.sh` (run after this) needs additionally:
#   OBS_WRITER_USERNAME / OBS_WRITER_PASSWORD
#   OBS_READER_USERNAME / OBS_READER_PASSWORD
# (also defined in .env.example so a single `source .env` covers all of them.)

set -euo pipefail

mode="${1:-create}"

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
echo "  2. Run scripts/setup-postgres.sh to create the schema +"
echo "     obs_writer/obs_reader roles + apply migrations. Set PG_HOST and"
echo "     PG_ADMIN_PASSWORD first; if you set provisionPostgres=false above,"
echo "     point PG_HOST at your existing Postgres."
echo "  3. Each tool (doc_search, hermes, …) sets the same two ENV vars in"
echo "     dev/stage/prod — only APP_ENV differs."
