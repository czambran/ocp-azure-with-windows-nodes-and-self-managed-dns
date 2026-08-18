#!/usr/bin/env bash
# Create Azure resources for Microsoft Entra Workload ID (short-term credentials).
# Run from your installation directory after extract-ccoctl.example.sh.
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
  echo "Azure CLI (az) is required. Install it and run az login first." >&2
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "Run az login before create-all." >&2
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

# Prefer az login user over VM managed identity (Azure VM bastions)
unset AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID AZURE_FEDERATED_TOKEN_FILE
export AZURE_TOKEN_CREDENTIALS=AzureCLICredential

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
  --preserve-existing-roles \
  "${EXTRA_ARGS[@]}"

echo "Confirmed --name=${INFRA_NAME} matches platform.azure.resourceGroupName in ${INSTALL_CONFIG}"
echo "Copy ${OUTPUT_DIR}/manifests/* to ./manifests/ and cp -a ${OUTPUT_DIR}/tls . before openshift-install create manifests"
