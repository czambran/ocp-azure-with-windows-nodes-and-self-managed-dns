#!/usr/bin/env bash
# Create Azure resources for Microsoft Entra Workload ID (short-term credentials).
# Run from your installation directory after extract-ccoctl.example.sh.
# Configure Azure credentials first — see docs/azure-install-identity.md
# Usage: ./examples/ccoctl-azure-create-all.example.sh [installation_directory]

set -euo pipefail

INSTALL_DIR="${1:-.}"
INSTALL_CONFIG="${INSTALL_CONFIG:-install-config.yaml}"
OUTPUT_DIR="${OUTPUT_DIR:-./ccoctl-output}"
CREDREQUESTS_DIR="${CREDREQUESTS_DIR:-./credrequests}"
# Set ENABLE_TECH_PREVIEW=1 for OCP 4.21 Technology Preview installs only.
ENABLE_TECH_PREVIEW="${ENABLE_TECH_PREVIEW:-0}"

cd "${INSTALL_DIR}"

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required to read values from ${INSTALL_CONFIG}." >&2
  exit 1
fi

if [[ ! -f "${INSTALL_CONFIG}" ]]; then
  echo "Missing ${INSTALL_CONFIG}. Create and configure it before running create-all." >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required. See docs/azure-install-identity.md." >&2
  exit 1
fi

# Read from install-config.yaml; env vars override when set.
INFRA_NAME="${INFRA_NAME:-$(yq -r '.platform.azure.resourceGroupName' "${INSTALL_CONFIG}")}"
REGION="${REGION:-$(yq -r '.platform.azure.region' "${INSTALL_CONFIG}")}"
DNS_ZONE_RG="${DNS_ZONE_RG:-$(yq -r '.platform.azure.baseDomainResourceGroupName' "${INSTALL_CONFIG}")}"
NETWORK_RG="${NETWORK_RG:-$(yq -r '.platform.azure.networkResourceGroupName' "${INSTALL_CONFIG}")}"

if [[ -z "${INFRA_NAME}" || "${INFRA_NAME}" == "null" ]]; then
  echo "Set platform.azure.resourceGroupName in ${INSTALL_CONFIG} before running create-all." >&2
  exit 1
fi

# OIDC issuer blob storage; 3-24 chars, lowercase letters and numbers only (no hyphens).
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-${INFRA_NAME}oidc}"
if [[ ! "${STORAGE_ACCOUNT_NAME}" =~ ^[a-z0-9]{3,24}$ ]]; then
  echo "STORAGE_ACCOUNT_NAME must be 3-24 lowercase letters or numbers. Set STORAGE_ACCOUNT_NAME explicitly." >&2
  exit 1
fi

# Credential selection — see docs/azure-install-identity.md
if [[ -n "${AZURE_CLIENT_ID:-}" && -n "${AZURE_CLIENT_SECRET:-}" ]]; then
  unset AZURE_TOKEN_CREDENTIALS
  export AZURE_TENANT_ID="${AZURE_TENANT_ID:-$(az account show --query tenantId -o tsv 2>/dev/null || true)}"
  if ! az account show >/dev/null 2>&1; then
    echo "Run az login --service-principal or configure az session. See docs/azure-install-identity.md." >&2
    exit 1
  fi
else
  unset AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_FEDERATED_TOKEN_FILE AZURE_AUTHORITY_HOST
  export AZURE_TOKEN_CREDENTIALS=AzureCLICredential
  if ! az account show >/dev/null 2>&1; then
    echo "Run az login or export service principal env vars. See docs/azure-install-identity.md." >&2
    exit 1
  fi
fi

TENANT_ID="$(az account show --query tenantId -o tsv)"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

EXTRA_ARGS=()
if [[ "${ENABLE_TECH_PREVIEW}" == "1" ]]; then
  EXTRA_ARGS+=(--enable-tech-preview)
fi

./ccoctl azure create-all \
  --name="${INFRA_NAME}" \
  --output-dir="${OUTPUT_DIR}" \
  --region="${REGION}" \
  --subscription-id="${SUBSCRIPTION_ID}" \
  --tenant-id="${TENANT_ID}" \
  --credentials-requests-dir="${CREDREQUESTS_DIR}" \
  --dnszone-resource-group-name="${DNS_ZONE_RG}" \
  --network-resource-group-name="${NETWORK_RG}" \
  --storage-account-name="${STORAGE_ACCOUNT_NAME}" \
  --preserve-existing-roles \
  "${EXTRA_ARGS[@]}"

echo "Confirmed --name=${INFRA_NAME} matches platform.azure.resourceGroupName in ${INSTALL_CONFIG}"
echo "Copy ${OUTPUT_DIR}/manifests/* to ./manifests/ and cp -a ${OUTPUT_DIR}/tls . before openshift-install create manifests"
