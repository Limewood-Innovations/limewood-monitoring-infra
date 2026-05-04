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
# After a successful deploy, this script writes PG_HOST=<POSTGRESFQDN> and
# KV_NAME=<KeyVault name> back into the repo-root .env so the operator can
# run setup-postgres.sh without additional config.

set -euo pipefail

mode="${1:-create}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
template="${repo_root}/bicep/main.bicep"
params="${repo_root}/bicep/parameters/main.bicepparam"
env_file="${repo_root}/.env"
location="westeurope"
deployment_name="alpenland-obs-$(date +%Y%m%d%H%M%S)"

# Auto-fetch deployer object id if not already exported. KeyVault module
# needs it to grant "Secrets Officer" RBAC. For users this is your AAD oid;
# in CI/SP scenarios, set AZ_DEPLOYER_OBJECT_ID explicitly to the SP oid.
if [[ -z "${AZ_DEPLOYER_OBJECT_ID:-}" ]]; then
    if AZ_DEPLOYER_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null)"; then
        export AZ_DEPLOYER_OBJECT_ID
        echo "→ Detected deployer object ID: ${AZ_DEPLOYER_OBJECT_ID}"
    else
        echo "ERROR: AZ_DEPLOYER_OBJECT_ID is not set and could not be auto-detected." >&2
        echo "       Run 'az login' first, or set AZ_DEPLOYER_OBJECT_ID manually." >&2
        exit 1
    fi
fi

# Auto-fetch the operator's public IPv4. Postgres firewall rule "AllowDeployer"
# uses it so setup-postgres.sh can connect from the laptop. CI / pipelines
# from inside Azure don't need this (AllowAllAzureIPs covers them) — set
# DEPLOYER_IP=skip explicitly to skip the firewall rule entirely.
if [[ -z "${DEPLOYER_IP:-}" ]]; then
    if DEPLOYER_IP="$(curl -fsS -4 https://ifconfig.me 2>/dev/null)" && [[ -n "${DEPLOYER_IP}" ]]; then
        export DEPLOYER_IP
        echo "→ Detected deployer public IP: ${DEPLOYER_IP}"
    else
        echo "⚠ Could not auto-detect public IP — Postgres firewall rule for"
        echo "  the operator skipped. setup-postgres.sh from a laptop will"
        echo "  fail with 'Connection refused' until you add a rule manually."
        export DEPLOYER_IP=''
    fi
elif [[ "${DEPLOYER_IP}" == "skip" ]]; then
    echo "→ DEPLOYER_IP=skip: operator firewall rule explicitly disabled"
    export DEPLOYER_IP=''
fi

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
# Auto-persist PG_HOST + KV_NAME into .env so setup-postgres.sh works
# without operator intervention. Both lines are idempotently replaced.
# --------------------------------------------------------------------------
pg_fqdn="$(jq -r '.properties.outputs.postgresFqdn.value // empty' "/tmp/${deployment_name}.json")"
kv_name="$(jq -r '.properties.outputs.keyVaultName.value // empty' "/tmp/${deployment_name}.json")"
ai_conn="$(jq -r '.properties.outputs.appInsightsConnectionString.value // empty' "/tmp/${deployment_name}.json")"

if [[ -f "${env_file}" ]]; then
    tmp_env="$(mktemp)"
    grep -v -E '^[[:space:]]*(PG_HOST|KV_NAME)=' "${env_file}" > "${tmp_env}" || true
    if [[ -n "${pg_fqdn}" && "${pg_fqdn}" != "(BYO"* ]]; then
        echo "PG_HOST=${pg_fqdn}" >> "${tmp_env}"
    fi
    if [[ -n "${kv_name}" ]]; then
        echo "KV_NAME=${kv_name}" >> "${tmp_env}"
    fi
    mv "${tmp_env}" "${env_file}"
    echo
    echo "✓ Wrote PG_HOST + KV_NAME into ${env_file}"
else
    echo
    echo "⚠ ${env_file} not found — set PG_HOST=${pg_fqdn} and KV_NAME=${kv_name}"
    echo "  manually before running setup-postgres.sh."
fi

# --------------------------------------------------------------------------
# Auto-store AppInsights connection string in KeyVault. The KV resource +
# RBAC role assignment for the deployer were just created above, so this
# `az keyvault secret set` is authorised by the same `az login` session
# that ran the Bicep deploy.
# --------------------------------------------------------------------------
if [[ -n "${kv_name}" && -n "${ai_conn}" ]]; then
    if command -v az >/dev/null 2>&1; then
        echo
        echo "→ Storing AppInsights connection string in KV ${kv_name}"
        # Bicep RBAC role assignments can take ~1 minute to propagate. Retry
        # on Forbidden so the operator doesn't have to re-run by hand.
        attempt=0
        until az keyvault secret set \
                --vault-name "${kv_name}" \
                --name appinsights-connection-string \
                --value "${ai_conn}" \
                --output none 2>/tmp/kv-set.err; do
            attempt=$((attempt + 1))
            if [[ ${attempt} -ge 6 ]]; then
                echo "⚠ Failed to store appinsights-connection-string after 6 attempts:" >&2
                cat /tmp/kv-set.err >&2
                echo "  Run manually:" >&2
                echo "    az keyvault secret set --vault-name ${kv_name} --name appinsights-connection-string --value '${ai_conn}'" >&2
                break
            fi
            echo "  RBAC propagation pending — retry ${attempt}/6 in 15s..."
            sleep 15
        done
        if [[ ${attempt} -lt 6 ]]; then
            echo "✓ Stored appinsights-connection-string in ${kv_name}"
        fi
    fi
fi

echo
echo "Next steps:"
echo "  1. Re-export the updated .env:    set -a; source .env; set +a"
echo "  2. Bootstrap the database:        ./scripts/setup-postgres.sh"
echo "     (creates schema + roles + writes the 3 PG URLs into KV)"
echo
echo "  All 4 KV secrets land automatically — nothing manual to copy-paste."
