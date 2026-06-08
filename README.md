# Instructions for how to set-up a Openshift cluster in Azure with Self-Managed DNS and Windows worker nodes

IPI currently assumes that all resources will be deployed in the same subscription. To be able to manage the DNS of a cluster with a public endopoint from a different subscription or from outside of Azure altogether, we can use the user-provisioned DNS capability of IPI that became available in Tech Preview for Azure in version 4.21

The steps below also include deploying the required changes to the OVN Network to support Windows-based worker nodes

# Pre-requisites
1. The openshift installer is installed
2. Dummy Public DNS hosted zone for the desired base domain(e.g: development.techcorp.com) has been created in the subscription where the cluster resources will be deployed. No records will be added to the Zone but it is needed to make the installer happy


# Steps

Note: The steps below are from the following documentation page: https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_azure/index#installation-initializing_installing-azure-customizations

The following steps assume that the openshif installer is already installed on the machine you will be using
to run the following commands:

1. Create a new directory (avoid reusing an existing directory) to house the files required for installation of the cluster. e.g: `mkdir ocp-cluster; cd ocp-cluster`
2. Generate the installation files: `openshift-install create install-config --dir .`. Follow the prompts and select the correct options for your deployment. Make sure to remember the name of the cluster as you will need this to create the required DNS records.
3. Open the newly created install-config.yaml file and make any changes necessary like the number of replicas, resource group for the network, etc...
4. To enabled the user-managed Technology Preview capabilities of the installer add the following as root level attributes in install-config.yaml:
```
featureSet: CustomNoUpgrade
featureGates: ["AzureClusterHostedDNSInstall=true"]
```
5. Look for the *platform* 'root' level attribute and add the child attribute "userProvisionedDNS" under the existing "azure" child-attribute of platform. The document will look something like this:
    ```
    ...
    platform:
        azure:
            userProvisionedDNS: Enabled
            ....
    ```
6. To run both Linux and Windows nodes in the same cluster we need to configure hybrid networking in OVN-Kubernetes. In order
   to do this we need to generate the Installation manifests from the install-config.yaml file. This process will **consume**
   the install-config.yaml file so please make a backup of it in case you need to run through the steps again with some minor modififications. You can see the complete documentation for this configuration [here](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_azure/index#configuring-hybrid-ovnkubernetes_installing-azure-customizations)

   6.1 Generate manifest files by running: `openshift-install create manifests --dir .`
   6.2 Create an empty yaml file to host the content we need to specify the hybrid networ: `touch manifests/cluster-network-03-config.yml`
   6.3 Edit the file using your preferred editor and add the following content:

```
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
    name: cluster
spec:
    defaultNetwork:
        ovnKubernetesConfig:
            hybridOverlayConfig:
                hybridClusterNetwork:
                # This is the next CIDR range from the one that the installer generated for the non-windows worker nodes. Adjust as needed
                - cidr: 10.132.0.0/14 
                  hostPrefix: 23
```

   6.4. Save the changes and back-up the file in case you need to recreate the cluster
   6.5. Deploy the cluster: `openshift-install create cluster --dir . --log-level=info`
   6.6. When user-managed DNS is enabled, components of the cluster will know how to reach the Control Plane to complete the installation but the installer will not as it is outside the cluster. Once you see the following output from the installer script, it is time to update the authoritative hosted zone (not the dummy one we created to make the installer happy) for the chosen domain: `INFO Waiting up to 45m0s (until X:XX XX) for bootstrapping to complete`.  See the instructions for this below
   

## Updates to authoritative Hosted Zone to complete cluster deployment

Note: If you would like to collect the IPs using the az CLI, see the following [page](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_azure/index#installation-azure-provisioning-own-dns-records_installing-azure-customizations)

   1. Collect the public IP for the API server from the Public Load Balancer created by the installer. It will be the Load Balancer with the name that **doesn't end** with '-int' and for the rule that listens on port 6443
   2. Add an A record for the following entry `api.<cluster_name>.<base_domain>` that points to the IP collected in the previous step
   3. Collect the public IP for the Ingress Gateway/Routes Endpoints (This is required to access the Openshift Web Console) from the Public Load Balancer created by the installer. It will be the Load Balancer with the name that *doesn't end* with '-int' and for the rule that listens on port 443. It may take a about 10 minutes to see the additional Load Balancer Rules
   4. Add an A record for the following entry `*.apps.<cluster_name>.<base_domain>` that points to the IP collected in the previous step
       

## Additional updates to deploy Windows worker nodes

Note: The commands below assume your oc context has been set 

1. Deploy the Windows Machine Config Operator (wcmo): `oc apply -f PATH-TO/wmco-subscription.yaml`
2. Wait a few minutes for the Operator deployment request to reconcile
3. Verify that the operator was deployed successfully using the following command and confirming that the phase columns shows "Succeeded": `oc get csv -n openshift-windows-machine-config-operator`
4. Create a new SSH keypair that will used by the Operator to communicate with the Windows hosts. It is **recommended** that this key be different than the one used when creating the cluster. You can use the following command to create the new keypair: `ssh-keygen -t ecdsa -b 256 -f ./windows_ecdsa`
5. Create the secret required by the operator with the SSH private key generated in the previous steps: `oc create secret generic cloud-private-key --from-file=private-key.pem=./windows_ecdsa -n openshift-windows-machine-config-operator`
6. Confirm the Operator was able to create a new secret with the user data that will be used to launch new Windows worker nodes: `oc -n openshift-machine-api get secret windows-user-data`
7. Create a new MachineSet using the template provided in the repo. The MachineSet name must be **9 characters or fewer** on Azure. Adjust `<location>` and `<zone>` to match your cluster region and availability zone from `install-config.yaml`. Example for a MachineSet named `windows1` in `eastus` AZ `1`:

```bash
cat ./azure-machineset_windows_2022.yaml | \
  sed "s/<infrastructure_id>/$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')/g" | \
  sed "s/<windows_machine_set_name>/windows1/g" | \
  sed "s/<location>/eastus/g" | \
  sed "s/<zone>/1/g" | \
  oc apply -f -
```