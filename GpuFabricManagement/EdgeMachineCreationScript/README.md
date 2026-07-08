## Create Edge Machines for an Azure Local cluster

GPU Management for Azure Local relies on **Edge Machine** resources, one per physical node in your cluster, to surface GPU inventory and health in Azure. These resources are normally provisioned for you, but for preview scenarios you can create them yourself.

This PowerShell [module](./CreateEdgeMachinesForCluster.psm1) does this for you: point it at your cluster and it will discover the cluster's nodes and create a matching Edge Machine resource for each one.

> **Note:** This module is intended for preview and evaluation scenarios only.

### Prerequisites
- The Az PowerShell module (`Az.Accounts` 5.3.1 or later).
- Sign in with `Connect-AzAccount -Tenant <tenantId>` and select the subscription that contains your Azure Local cluster (`Set-AzContext -Subscription <id>`).
- The **Contributor** or **Azure Stack HCI Administrator** role on the cluster's resource group, which grants the permissions needed to create the Edge Machine resources.
- Azure Local medium cluster with version 12.2604.1003 or later.
- The script must be run from a machine that has connectivity to the Azure control plane (ARM).

### Usage

To run the script, first download the file and import the module into your local PowerShell session

```powershell
Import-Module CreateEdgeMachinesForCluster.psm1
```

> **Note:** This script is not digitally signed, so importing it may fail with a security exception such as *"cannot be loaded because running scripts is disabled on this system"* or *"...is not digitally signed"*. Because the file was downloaded from the internet, Windows also blocks it via the Mark of the Web. To resolve this, unblock the file and allow it to run in your current session:
>
> ```powershell
> # Remove the "downloaded from the internet" flag
> Unblock-File -Path .\CreateEdgeMachinesForCluster.psm1
>
> # Allow unsigned local scripts for the current PowerShell session only
> Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
> ```
>
> The `-Scope Process` setting applies only to the current session and reverts when you close the window, so it does not change your machine-wide execution policy.

First, try running the script with `WhatIf` to see what resources will get created

```powershell
New-EdgeMachinesForCluster -ClusterResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/clusters/<name>" -WhatIf
```

Once you're ready, you can run the script without `-WhatIf` to create the Edge Machines

```powershell
New-EdgeMachinesForCluster -ClusterResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/clusters/<name>"
```

It may take up to 30 minutes after the creation of the Edge Machine resources before GPU management is available. If they still don't show up, check the GPU drivers on your machines.

This script is safe to run; the newly created Edge Machine resources won't have any adverse effects on the normal operations of your cluster. These new resources are also not billed separately from the cluster.
