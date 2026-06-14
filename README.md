# OpenShift on Azure with Self-Managed DNS and Windows Worker Nodes

## Overview

Installer-provisioned infrastructure (IPI) on Azure normally assumes all resources deploy in the same subscription. This guide addresses two common enterprise constraints:

- **DNS** is managed in a **different subscription** or **outside Azure** — use user-provisioned DNS (Tech Preview in OpenShift Container Platform **4.21+**).
- **Networking** is pre-provisioned in a **separate resource group within the same subscription** where the installer creates cluster resources — the OpenShift installer consumes an existing VNet and subnets rather than creating them.

The guide also covers the OVN-Kubernetes hybrid overlay configuration required to run **Linux and Windows worker nodes** in the same cluster. Windows workers are added post-install via WMCO and attach to the same pre-provisioned compute subnet as Linux workers.

Official references:
- [Installing a cluster with customizations on Azure](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_azure/index#installation-initializing_installing-azure-customizations)
- [Reusing a VNet](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/installing_on_azure/installer-provisioned-infrastructure#installation-platform-azure-vnet_installing-azure-customizations)

## Architecture

```mermaid
flowchart TB
  subgraph computeSub [Compute subscription]
    subgraph networkRG [Network resource group]
      VNet[Existing VNet]
      CPSubnet[controlPlaneSubnet]
      WorkerSubnet[computeSubnet]
    end
    subgraph clusterRG [Cluster resource group]
      ControlPlane[Control plane VMs]
      LinuxWorkers[Linux worker VMs]
      WinWorkers[Windows worker VMs]
      LB[Load balancers]
      WMCO[WMCO]
      HybridOVN[Hybrid OVN overlay]
    end
    subgraph dummyDnsRG [Dummy DNS resource group]
      DummyZone[Dummy DNS zone]
    end
  end
  subgraph dnsElsewhere [DNS subscription or external]
    AuthZone[Authoritative DNS zone]
  end
  Installer[openshift-install] --> VNet
  Installer --> clusterRG
  ControlPlane --> CPSubnet
  LinuxWorkers --> WorkerSubnet
  WinWorkers --> WorkerSubnet
  WMCO --> WinWorkers
  HybridOVN --> LinuxWorkers
  HybridOVN --> WinWorkers
  LB --> AuthZone
```

- **Network resource group (same subscription):** pre-provisioned VNet, control plane subnet, and compute subnet. All cluster and Windows worker NICs attach to subnets here.
- **Cluster resource group (same subscription):** control plane VMs, Linux workers, Windows workers (via WMCO), load balancers, disks, and identities — created by the installer.
- **Dummy DNS resource group (same subscription):** empty DNS zone required by the installer when using user-provisioned DNS. No customer-facing records are added here.
- **DNS subscription (or external DNS):** authoritative `api` and `*.apps` records customers use to reach the cluster.

## Prerequisites

1. The OpenShift installer is installed on the machine used to run installation commands.
2. (Optional: Only needed when generating the install-config.yaml through the installer propmpts) A dummy public DNS hosted zone for the desired base domain (e.g. `development.techcorp.com`) exists in the subscription where cluster resources will be deployed. No records are added to this zone — it satisfies the installer only.
3. The `oc` CLI is installed (required after cluster installation for Windows node steps).
4. The cluster name in `install-config.yaml` must **not** contain `windows`, `microsoft`, or similar words (Azure identity naming restriction).
5. A VNet and subnets exist in a **network resource group** in the same subscription used for cluster installation.
6. Two subnets are available: one for the **control plane** (`controlPlaneSubnet`) and one for **compute/worker** nodes (`computeSubnet`). Windows workers use the compute subnet. The compute subnet (and its route table/NSG) must allow **outbound internet access** — WMCO downloads and installs the OpenSSH server from the Microsoft Store when configuring each Windows node.
7. The VNet CIDR contains the `networking.machineNetwork` CIDR you will set in `install-config.yaml`.
8. Subnets use Azure-assigned DHCP (not static IP assignments).
9. Network security group rules for required cluster ports (6443, 443, 22623, etc.) are in place **before** installation. See the [VNet NSG requirements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/installing_on_azure/installer-provisioned-infrastructure#installation-platform-azure-vnet_installing-azure-customizations).
10. The Azure service principal used for installation can access both the **network resource group** and the resource groups where cluster and DNS resources are created.

## Phase 1: Install the cluster

The steps below assume the OpenShift installer is installed on the machine you will use to run the following commands.

1. Create a new directory (avoid reusing an existing directory) to house the files required for installation of the cluster. e.g. `mkdir ocp-cluster; cd ocp-cluster`
2. Generate the installation files: `openshift-install create install-config --dir .`. Follow the prompts and select the correct options for your deployment. When prompted, provide the network resource group, VNet, and subnet names from your pre-provisioned network landing zone. Make sure to remember the cluster name — you will need it to create DNS records.
3. Open the newly created `install-config.yaml` file and configure replicas, `networking.machineNetwork`, and the pre-provisioned network fields under `platform.azure` (see step 5).
4. To enable the user-managed Technology Preview capabilities of the installer, add the following as root-level attributes in `install-config.yaml`:

```yaml
featureSet: CustomNoUpgrade
featureGates: ["AzureClusterHostedDNSInstall=true"]
```

5. Under `platform.azure`, reference your pre-provisioned VNet and enable user-provisioned DNS. The guide-specific fields in `install-config.yaml` should look like this (adjust values for your environment; do not copy pull secrets or SSH keys from this example):

```yaml
featureSet: CustomNoUpgrade
featureGates: ["AzureClusterHostedDNSInstall=true"]
baseDomain: development.techcorp.com
metadata:
  name: mycluster
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 10.0.0.0/16
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
platform:
  azure:
    region: eastus
    baseDomainResourceGroupName: dummy-dns-rg
    networkResourceGroupName: example-network-rg
    virtualNetwork: example-vnet
    controlPlaneSubnet: example-controlplane-subnet
    computeSubnet: example-worker-subnet
    userProvisionedDNS: Enabled
```

Set `networking.machineNetwork` to an address range that fits within your VNet CIDR and the subnet ranges you provide. The installer creates cluster resources in its own resource group; it does **not** create the VNet or subnets.

See also: [examples/install-config.snippet.yaml](./examples/install-config.snippet.yaml)

6. To run both Linux and Windows nodes in the same cluster, configure hybrid networking in OVN-Kubernetes. Generate installation manifests from `install-config.yaml`. This process will **consume** the `install-config.yaml` file, so back it up first. See the [hybrid OVN-Kubernetes documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_azure/index#configuring-hybrid-ovnkubernetes_installing-azure-customizations) for details.

   6.1 Generate manifest files: `openshift-install create manifests --dir .`

   6.2 Create the hybrid network manifest: `touch manifests/cluster-network-03-config.yml`

   6.3 Edit the file and add the following content. Set `hybridClusterNetwork.cidr` to a range that **does not overlap** with `networking.clusterNetwork` in your backed-up `install-config.yaml`. For example, if `clusterNetwork` is `10.128.0.0/14`, use the next block such as `10.132.0.0/14`:

```yaml
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
      hybridOverlayConfig:
        hybridClusterNetwork:
        - cidr: 10.132.0.0/14
          hostPrefix: 23
```

   Do **not** set `hybridOverlayVXLANPort` on Azure. That setting is required only for vSphere clusters.

   See also: [examples/cluster-network-03-config.yml](./examples/cluster-network-03-config.yml)

   6.4 Save the changes and back up the file in case you need to recreate the cluster.

   6.5 Deploy the cluster: `openshift-install create cluster --dir . --log-level=info`

   6.6 When user-managed DNS is enabled, cluster components can reach the control plane, but the installer host cannot resolve cluster-internal DNS. When you see `INFO Waiting up to 45m0s (until X:XX XX) for bootstrapping to complete`, update the **authoritative** hosted zone (not the dummy zone) as described below.

### Update authoritative DNS to complete installation

Note: To collect IPs using the Azure CLI, see [Provisioning your own DNS records](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_azure/index#installation-azure-provisioning-own-dns-records_installing-azure-customizations).

1. Collect the public IP for the API server from the public load balancer created by the installer — the load balancer whose name **does not** end with `-int`, for the rule listening on port **6443**.
2. Add an A record for `api.<cluster_name>.<base_domain>` pointing to that IP.
3. Collect the public IP for the Ingress/routes endpoint (required for the OpenShift web console) from the same public load balancer, for the rule listening on port **443**. It may take about 10 minutes for this rule to appear.
4. Add an A record for `*.apps.<cluster_name>.<base_domain>` pointing to the Ingress IP.

Windows workers require an additional `api-int` record — see Phase 2.

## Phase 2: Deploy Windows worker nodes

Note: The commands below assume your `oc` context is set to the installed cluster.

Windows node bootstrap requires outbound connectivity from the **compute subnet** to the internet (or an approved egress path). WMCO installs OpenSSH on each Windows VM by downloading it from the **Microsoft Store** during node configuration. Restricted subnets without outbound access will cause Windows Machines to stall or fail during WMCO setup.

Before applying a Windows MachineSet, create the `api-int` DNS record as described below. Windows worker bootstrap requires this record; Linux workers do not.

### Create api-int DNS record for Windows workers

Windows VMs resolve the internal Kubernetes API at `api-int.<cluster_name>.<base_domain>` using your **authoritative** hosted zone (the same zone as `api` and `*.apps`, not the dummy zone) until WMCO finishes configuring them as worker nodes. The record must point to the **private IP** of the internal load balancer (`${infra_id}-internal`), not the public API load balancer.

1. In the cluster resource group, identify the internal load balancer named `${infra_id}-internal` (the load balancer whose name ends with `-internal`). Get `${infra_id}` from:

   `oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}'`

2. Collect the **private** IP from the load balancer rule listening on port **6443**.

   Optional Azure CLI:

```bash
infra_id=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
cluster_resource_group_name="${infra_id}-rg"
lb_name="${infra_id}-internal"

frontendipconfig_id=$(az network lb show -n "${lb_name}" -g "${cluster_resource_group_name}" \
  --query "loadBalancingRules[?frontendPort==\`6443\`].frontendIPConfiguration.id | [0]" -o tsv)

frontendipconfig_name=${frontendipconfig_id##*/}

az network lb frontend-ip show -n "${frontendipconfig_name}" --lb-name "${lb_name}" \
  -g "${cluster_resource_group_name}" --query "privateIPAddress" -o tsv
```

   The last command prints the private IP to use for the `api-int` A record in step 3.

3. In your authoritative hosted zone, add an **A record** for `api-int.<cluster_name>.<base_domain>` pointing to that private IP.

4. Verify the record in your **authoritative DNS zone**.

```bash
dig +noall +answer @8.8.8.8 api-int.<cluster_name>.<base_domain>
```

   Confirm the returned A record IP matches the internal load balancer private IP from step 2.

### Install WMCO and create a Windows MachineSet

1. Deploy the Windows Machine Config Operator (WMCO): `oc apply -f ./wmco-subscription.yaml`
2. Wait a few minutes for the operator deployment request to reconcile.
3. Verify the operator deployed successfully — the CSV phase column should show `Succeeded`:

   `oc get csv -n openshift-windows-machine-config-operator`

4. Create a new SSH keypair for the operator to communicate with Windows hosts. It is **recommended** that this key differ from the cluster installation key:

   `ssh-keygen -t ecdsa -b 256 -f ./windows_ecdsa`

5. Create the secret required by the operator:

   `oc create secret generic cloud-private-key --from-file=private-key.pem=./windows_ecdsa -n openshift-windows-machine-config-operator`

6. Confirm WMCO created the `windows-user-data` secret in `openshift-machine-api`. This secret is created when WMCO deploys. Verify with:

   `oc -n openshift-machine-api get secret windows-user-data`

   If the secret is missing, check the WMCO CSV, operator pods, and events.

7. Create a Windows MachineSet using the template in this repo. The MachineSet name must be **9 characters or fewer** on Azure. Set network placeholders to match your backed-up `install-config.yaml` — **not** the installer-default `{infra_id}-vnet` / `{infra_id}-worker-subnet` names. Example for a MachineSet named `windows1` in `eastus` AZ `1`:

```bash
cat ./azure-machineset_windows_2022.yaml | \
  sed "s/<infrastructure_id>/$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')/g" | \
  sed "s/<windows_machine_set_name>/windows1/g" | \
  sed "s/<location>/eastus/g" | \
  sed "s/<zone>/1/g" | \
  sed "s/<network_resource_group>/example-network-rg/g" | \
  sed "s/<vnet_name>/example-vnet/g" | \
  sed "s/<compute_subnet>/example-worker-subnet/g" | \
  oc apply -f -
```

Replace `example-network-rg`, `example-vnet`, and `example-worker-subnet` with the values from `platform.azure.networkResourceGroupName`, `platform.azure.virtualNetwork`, and `platform.azure.computeSubnet` in your install-config backup.

8. Verify the MachineSet created a **Machine** resource. A Windows worker node will not appear immediately — bootstrapping takes time:

```bash
oc get machineset windows1 -n openshift-machine-api
oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset=windows1
```

   Wait for the Machine to reach `Running` phase and for WMCO to finish configuring the VM before expecting a node.

9. After bootstrap completes (this may take 10+ minutes), verify the Windows **node** joined the cluster:

```bash
oc get nodes -l node.openshift.io/os_id=Windows
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Installer stuck at bootstrap | External DNS not pointing to API load balancer | Add `api.<cluster>.<base_domain>` A record; verify resolution from the install bastion |
| Console unreachable | Missing `*.apps.*` DNS record | Wait for the port 443 load balancer rule (~10 min), then add the Ingress IP |
| Install fails validating subnets | Wrong subnet names or network resource group | Verify `networkResourceGroupName`, `virtualNetwork`, `controlPlaneSubnet`, and `computeSubnet` in `install-config.yaml` |
| Install fails on Azure API / NSG | Missing NSG rules on network subnets | Apply required port rules before install (see Red Hat VNet NSG requirements) |
| `windows-user-data` missing after WMCO install | WMCO failed to reconcile on deploy | Check WMCO operator pods, logs, and events — do not wait for a MachineSet |
| Windows Machine fails to provision | MachineSet uses installer-default VNet/subnet names | Set `networkResourceGroup`, `vnet`, and `subnet` to pre-provisioned values from install-config |
| Windows Machine stuck / node never Ready | Compute subnet blocks outbound internet | Allow egress from the compute subnet so WMCO can download OpenSSH from the Microsoft Store |
| Windows Machine / node fails to join | Missing or wrong `api-int` DNS for Windows workers | Add A record for `api-int.<cluster>.<base_domain>` → private IP of `${infra_id}-internal` LB; verify with `dig @8.8.8.8 api-int...` — do not rely on resolution from a Linux worker node (cluster DNS) |
| MachineSet fails or VM name error | MachineSet name too long for Azure | MachineSet name must be **9 characters or fewer** |
| Install timed out after DNS was fixed | Installer did not resume automatically | Run `openshift-install wait-for install-complete --dir . --log-level=info` |

## Reference files

| File | Purpose |
|------|---------|
| [examples/install-config.snippet.yaml](./examples/install-config.snippet.yaml) | Guide-specific `install-config.yaml` fields including pre-provisioned VNet |
| [examples/cluster-network-03-config.yml](./examples/cluster-network-03-config.yml) | Hybrid OVN-Kubernetes overlay manifest |
| [wmco-subscription.yaml](./wmco-subscription.yaml) | WMCO OperatorGroup and Subscription |
| [azure-machineset_windows_2022.yaml](./azure-machineset_windows_2022.yaml) | Windows Server 2022 MachineSet template |
