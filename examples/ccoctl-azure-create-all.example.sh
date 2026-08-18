#!/usr/bin/env bash
# Create Azure resources for Microsoft Entra Workload ID (short-term credentials).
# Run from your installation directory after extract-ccoctl.example.sh.
# Usage: ./examples/ccoctl-azure-create-all.example.sh [installation_directory]

set -euo pipefail

INSTALL_DIR="${1:-.}"

# --- Adjust these values for your environment ---
INFRA_NAME="${INFRA_NAME:-demo1rg}"
REGION="${REGION:-eastus}"
DNS_ZONE_RG="${DNS_ZONE_RG:-dummy-dns-rg}"
NETWORK_RG="${NETWORK_RG:-example-network-rg}"
OUTPUT_DIR="${OUTPUT_DIR:-./ccoctl-output}"
CREDREQUESTS_DIR="${CREDREQUESTS_DIR:-./credrequests}"
# Set ENABLE_TECH_PREVIEW=1 for OCP 4.21 Technology Preview installs only.
ENABLE_TECH_PREVIEW="${ENABLE_TECH_PREVIEW:-0}"

cd "${INSTALL_DIR}"

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required. Install it and run az login first." >&2
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "Run az login before create-all." >&2
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

echo "Add platform.azure.resourceGroupName: ${INFRA_NAME} to install-config.yaml before openshift-install create manifests"
echo "Then copy ${OUTPUT_DIR}/manifests/* to ./manifests/ and cp -a ${OUTPUT_DIR}/tls ."
