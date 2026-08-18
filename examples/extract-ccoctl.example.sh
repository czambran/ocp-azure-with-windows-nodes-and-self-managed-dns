#!/usr/bin/env bash
# Extract ccoctl and CredentialsRequest objects for Azure Workload Identities.
# Run from your installation directory after install-config.yaml is configured.
# Usage: ./examples/extract-ccoctl.example.sh [installation_directory]

set -euo pipefail

INSTALL_DIR="${1:-.}"
PULL_SECRET="${PULL_SECRET:-pull-secret}"

cd "${INSTALL_DIR}"

RELEASE_IMAGE="$(openshift-install version | awk '/release image/ {print $3}')"

# On RHEL 9 hosts, use: oc adm release extract --command=ccoctl.rhel9 ...
oc adm release extract --command=ccoctl "${RELEASE_IMAGE}" -a "${PULL_SECRET}"
chmod 775 ccoctl

oc adm release extract --from="${RELEASE_IMAGE}" \
  --credentials-requests --included \
  --install-config=./install-config.yaml \
  --to=./credrequests \
  -a "${PULL_SECRET}"

echo "ccoctl and credrequests are ready in ${INSTALL_DIR}"
