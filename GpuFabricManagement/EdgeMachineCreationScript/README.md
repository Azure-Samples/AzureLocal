## Create Edge Machines for an Azure Local cluster

All Azure Local medium clusters created using the new Simplified Machine Provisioning flow are accompanied by the newly added Edge Machine resources. Certain new features like GPU Management are built on top of this Edge Machine resource. For parity, we'll be migrating all Azure Local medium clusters to Edge Machine in our 2610 release. If you want to try out GPU Management prior to this release, you can create the Edge Machine resources yourself. The PowerShell [module](./CreateEdgeMachinesForCluster.psm1) allows you to create these Edge Machine resources.

### Prerequisites
- The Az PowerShell module ( `Az.Accounts`  5.3.1 or later)
- Sign in with `Connect-AzAccount` and select the subscription that contains your Azure Local cluster ( `Set-AzContext -Subscription <id>` )
- Permission to create resources in the cluster's resource group
- Azure Local medium cluster with version 12.2604.1003 or later

### Usage

To run the script, first download the file and import the module into your local PowerShell session

```powershell
Import-Module CreateEdgeMachinesForCluster.psm1
```

First, try running the script with `WhatIf` to see what resources will get created

```powershell
New-EdgeMachinesForCluster -ClusterResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/clusters/<name>" -WhatIf
```

Once you're ready, you can run the script without `-WhatIf` to create the Edge Machines

```powershell
New-EdgeMachinesForCluster -ClusterResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/clusters/<name>"
```

You can also pass `-Confirm:$false` to skip the confirmation prompt. This might be useful if you are trying to automate this process across all your clusters.

```powershell
New-EdgeMachinesForCluster -ClusterResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/clusters/<name>" -Confirm:$false
```

It may take up to 30 minutes after the creation of the Edge Machine resources before GPU management is available. If they still don't show up, check the GPU drivers on your machines.

This script is safe to run; the newly created Edge Machine resources won't have any adverse effects on the normal operations of your cluster. These new resources are also not billed separately from the cluster.
