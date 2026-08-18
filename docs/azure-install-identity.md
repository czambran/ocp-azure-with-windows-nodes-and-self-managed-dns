# Azure identity for install bastions

This guide uses **Microsoft Entra Workload ID** with short-term credentials for cluster components (`credentialsMode: Manual` + `ccoctl`). That is separate from **install-time** authentication on the bastion host.

Install commands are usually run from an **Azure VM**. That VM may have its own **managed identity**, which the OpenShift installer and `ccoctl` can pick up automatically. Interactive `az login` does **not** supply a client secret for `openshift-install` prompts.

## Three credential contexts

| Context | Used by | What authenticates |
|---------|---------|----------------------|
| **Install-time** | `openshift-install` (`create install-config`, `create manifests`, `create cluster`) | **Service principal** (application ID + client secret) **or** the VM **managed identity** |
| **ccoctl** | `ccoctl azure create-all` | **Service principal** environment variables **or** interactive user (`az login` + `AZURE_TOKEN_CREDENTIALS=AzureCLICredential`) |
| **Cluster runtime** | Cloud Credential Operator and cloud-aware operators | User-assigned **managed identities** created by `ccoctl` (not your user login or install SP) |

`az login` alone is sufficient only for `ccoctl` when you force the Azure CLI credential path. It is **not** a substitute for the service principal `clientId` and `clientSecret` that `openshift-install` expects (unless you intentionally use the VM managed identity for install).

## Recommended: one service principal

Use a **dedicated service principal** with permissions to create resource groups, storage, user-assigned managed identities, and role assignments in the target subscription. See [Azure permissions for installer-provisioned infrastructure](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_azure/installer-provisioned-infrastructure#installation-azure-permissions_installing-azure-customizations).

1. Create the service principal (commands below) and note the **application (client) ID**, **client secret**, **tenant ID**, and **subscription ID**.
2. Use that service principal for **both** `openshift-install` and `ccoctl` so credential selection stays consistent on the bastion.

### Create the service principal

Run these commands as an Azure user who can create service principals and assign roles on the target subscription. The creating account needs **Contributor** and **User Access Administrator** on the subscription (or equivalent custom permissions). To create a service principal, the account also needs the `microsoft.directory/servicePrincipals/createAsOwner` permission in Microsoft Entra ID.

```bash
# Sign in as the administrator who will create the install service principal
az login

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
SP_NAME="ocp-azure-install-sp"   # change if desired

az account set --subscription "${SUBSCRIPTION_ID}"

# Contributor at subscription scope (required for openshift-install)
az ad sp create-for-rbac \
  --name "${SP_NAME}" \
  --role Contributor \
  --scopes "/subscriptions/${SUBSCRIPTION_ID}"
```

The command prints JSON. **Copy and protect these values** — the client secret (`password`) is shown only once:

```json
{
  "appId": "<application_client_id>",
  "displayName": "ocp-azure-install-sp",
  "password": "<client_secret>",
  "tenantId": "<tenant_id>"
}
```

Assign **User Access Administrator** on the same subscription. `ccoctl azure create-all` needs this role to create user-assigned managed identities and role assignments:

```bash
export AZURE_CLIENT_ID="<application_client_id>"   # appId from create-for-rbac output

az role assignment create \
  --role "User Access Administrator" \
  --assignee-object-id "$(az ad sp show --id "${AZURE_CLIENT_ID}" --query id -o tsv)" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}"
```

Store credentials for use on the install bastion (replace values from the `create-for-rbac` output):

```bash
export AZURE_CLIENT_ID="<application_client_id>"
export AZURE_CLIENT_SECRET="<client_secret>"
export AZURE_TENANT_ID="<tenant_id>"
unset AZURE_TOKEN_CREDENTIALS
```

Verify the service principal can access the subscription:

```bash
az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"
az account show --query "{subscription:id, name:name, tenant:tenantId}" -o table
```

Do not commit these values to git or share them in tickets. Rotate the secret in Entra ID if it is exposed.

### Before `openshift-install create install-config`

When the installer prompts for Azure credentials, provide the service principal **application ID** and **client secret**.

If you previously ran the installer on this host with a different identity, remove the cached profile:

```bash
rm -f ~/.azure/osServicePrincipal.json
```

### Before `ccoctl azure create-all`

If not already exported, set the same service principal variables from [Create the service principal](#create-the-service-principal):

```bash
export AZURE_CLIENT_ID="<application_client_id>"
export AZURE_CLIENT_SECRET="<client_secret>"
export AZURE_TENANT_ID="<tenant_id>"
unset AZURE_TOKEN_CREDENTIALS
```

If the bastion `az` session is not already using the service principal, sign in and select the subscription:

```bash
az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}"
az account set --subscription "<subscription_id>"
az account show --query "{subscription:id, name:name}" -o table
```

## Azure VM bastions and managed identity

If the install VM has a **system-assigned or user-assigned managed identity**, `ccoctl` and `openshift-install` may use it instead of your intended account:

- `ccoctl` uses `DefaultAzureCredential`, which tries the VM managed identity **before** `az login`.
- `openshift-install` on Azure may create or reuse `~/.azure/osServicePrincipal.json` tied to the VM identity when no client secret is supplied.

**Options:**

1. **Recommended:** Use a service principal (above) for both tools and remove `~/.azure/osServicePrincipal.json` before install.
2. **VM managed identity for install only:** Assign the VM identity install permissions and do not rely on `az login` for `openshift-install`. You still need a separate auth path for `ccoctl` if the VM identity lacks permissions for `create-all`.
3. **Remove managed identity from the install VM** if it is not required for other workloads, then use a service principal.

## Optional: interactive user for `ccoctl` only

Use this only when a human operator with sufficient Azure RBAC runs `ccoctl` and you do **not** export service principal variables for `ccoctl`.

`openshift-install` still needs a **service principal client secret** (or VM managed identity) as described above. `az login` does not replace that.

```bash
unset AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID \
  AZURE_FEDERATED_TOKEN_FILE AZURE_AUTHORITY_HOST

az login
az account set --subscription "<subscription_id>"

export AZURE_TOKEN_CREDENTIALS=AzureCLICredential

az account show --query "{subscription:id, user:user.name, tenant:tenantId}" -o table
az ad signed-in-user show --query "{displayName:userPrincipalName}" -o table
```

If `ccoctl` still fails with permission errors, the VM managed identity may still be winning credential selection — unset any `AZURE_CLIENT_ID` set for a user-assigned identity on the VM, or use the service principal workflow instead.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `ccoctl create-all` permission errors on Azure VM | VM managed identity used instead of intended account | Use service principal env vars, or `export AZURE_TOKEN_CREDENTIALS=AzureCLICredential` after `az login` and unset `AZURE_CLIENT_ID` |
| Installer uses VM identity despite `az login` | Cached `osServicePrincipal.json` or blank client secret at prompt | `rm ~/.azure/osServicePrincipal.json`; provide service principal **client ID + secret** when prompted |
| `openshift-install` prompts fail after `az login` only | Installer requires SP secret or VM MI, not user session | Create a service principal with install permissions and use it at the prompts |
| Wrong subscription | Stale `az` session | `az account set --subscription "<subscription_id>"` and verify with `az account show` |

## References

- [Configuring an Azure cluster to use short-term credentials](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_azure/installer-provisioned-infrastructure#cco-short-term-credentials_installing-azure-customizations)
- [Manual mode with short-term credentials](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/authentication_and_authorization/managing-cloud-provider-credentials#cco-short-term-creds_managing-cloud-provider-credentials)
