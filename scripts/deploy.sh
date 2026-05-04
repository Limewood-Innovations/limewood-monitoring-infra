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
#
# After a successful deploy, this script writes PG_HOST=<POSTGRESFQDN> back
# into the repo-root .env so the operator can run setup-postgres.sh without
# additional config.

set -euo pipefail

mode="${1:-create}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
template="${repo_root}/bicep/main.bicep"
params="${repo_root}/bicep/parameters/main.bicepparam"
env_file="${repo_root}/.env"
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

# --------------------------------------------------------------------------
# Auto-persist PG_HOST in .env so setup-postgres.sh works without additional
# operator action. Overwrites any existing PG_HOST line (idempotent).
# --------------------------------------------------------------------------
pg_fqdn="$(jq -r '.properties.outputs.postgresFqdn.value // empty' "/tmp/${deployment_name}.json")"
if [[ -n "${pg_fqdn}" && "${pg_fqdn}" != "(BYO"* ]]; then
    if [[ -f "${env_file}" ]]; then
        # Strip any existing PG_HOST line, then append the fresh one.
        # macOS-compatible (no -i ''):
        tmp_env="$(mktemp)"
        grep -v -E '^[[:space:]]*PG_HOST=' "${env_file}" > "${tmp_env}" || true
        echo "PG_HOST=${pg_fqdn}" >> "${tmp_env}"
        mv "${tmp_env}" "${env_file}"
        echo
        echo "✓ Wrote PG_HOST=${pg_fqdn} into ${env_file}"
    else
        echo
        echo "⚠ ${env_file} not found — set PG_HOST=${pg_fqdn} manually before"
        echo "  running setup-postgres.sh."
    fi
fi

echo
echo "Next steps:"
echo "  1. Re-export the updated .env:    set -a; source .env; set +a"
echo "  2. Bootstrap the database:        ./scripts/setup-postgres.sh"
echo "  3. Stash the printed URLs in KeyVault (the script tells you exactly)."
echo "  4. Wire each tool (doc_search, hermes, …) with the KeyVault references"
echo "     for APPLICATIONINSIGHTS_CONNECTION_STRING + OBSERVABILITY_SQL_URL."
