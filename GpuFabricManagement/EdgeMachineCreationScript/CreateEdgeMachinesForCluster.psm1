#Requires -Version 5.1

function Invoke-AzRestGet {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    Write-Verbose "GET $Path"
    $response = Invoke-AzRestMethod -Method GET -Path $Path
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "GET failed (HTTP $($response.StatusCode)) for $Path`n$($response.Content)"
    }

    $text = ($response.Content | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Empty response body for $Path"
    }

    try {
        return $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to parse JSON from $Path`n$text"
    }
}

function Invoke-AzRestPut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Body
    )

    Write-Verbose "PUT $Path"
    Write-Verbose "Body: $Body"

    $response = Invoke-AzRestMethod -Method PUT -Path $Path -Payload $Body
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "PUT failed (HTTP $($response.StatusCode)) for $Path`n$($response.Content)"
    }
    return ($response.Content | Out-String).Trim()
}

<#
.SYNOPSIS
    Creates an EdgeMachine resource for every Arc machine in an Azure Stack
    HCI cluster, gated on each Arc machine reporting at least a minimum
    Azure Local solution version.

.DESCRIPTION
    1. GETs <ClusterResourceId>?api-version=2024-04-01 to read the cluster's
       location.
    2. GETs <ClusterResourceId>/arcSettings/default via Invoke-AzRestMethod,
       walks each perNodeDetails[].arcInstance, GETs the arc machine, and reads
       properties.detectedProperties["azurelocal.solutionversion"].
    3. Compares each reported value against the $MinVersion constant.
    4. If every node meets $MinVersion, PUTs an EdgeMachine resource for each
       Arc machine, reusing the Arc machine's name as the EdgeMachine name.
       Otherwise prints the failing nodes and throws without creating any
       EdgeMachine.

    Before issuing the PUT calls, the function prints the list of EdgeMachines
    it will create and asks for confirmation (Y/N). Pass `-Confirm:$false` to
    skip the prompt and create them immediately. Pass `-WhatIf` to print the
    list without creating anything.

    Requires the Az PowerShell module (Az.Accounts >= 5.3.1) and the user to be
    logged in via `Connect-AzAccount` with the cluster's subscription selected.
    The function verifies the active Az context's subscription matches the
    cluster and fails fast if it does not; it does not change the active
    subscription. REST calls go through Invoke-AzRestMethod using relative
    resource paths, which target the active cloud's ARM endpoint.

.PARAMETER ClusterResourceId
    Full ARM resource ID of the Microsoft.AzureStackHCI/clusters resource.

.EXAMPLE
    Import-Module .\CreateEdgeMachinesForClusterIfVsrVersionGreaterThan2604.psm1
    New-EdgeMachinesForCluster `
        -ClusterResourceId '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/clusters/<name>'

.EXAMPLE
    # Skip the confirmation prompt
    New-EdgeMachinesForCluster -ClusterResourceId '...' -Confirm:$false

.EXAMPLE
    # Dry-run: list the EdgeMachine PUTs without sending them
    New-EdgeMachinesForCluster -ClusterResourceId '...' -WhatIf
#>
function New-EdgeMachinesForCluster {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId
    )

    $ErrorActionPreference = 'Stop'

    # ---- Configuration ------------------------------------------------------
    # Minimum required azurelocal.solutionversion. EdgeMachine resources will
    # only be created when EVERY arc machine in the cluster reports a version
    # >= this.
    $MinVersion = '12.2604.1003'

    $ClusterApiVersion     = '2024-04-01'
    $ArcSettingsApiVersion = '2024-04-01'
    $ArcMachineApiVersion  = '2024-07-10'
    $EdgeMachineApiVersion = '2026-05-01-preview'
    $SolutionVersionKey    = 'azurelocal.solutionversion'
    # -------------------------------------------------------------------------

    $clusterIdPattern = '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.AzureStackHCI/clusters/([^/]+)$'
    if ($ClusterResourceId -notmatch $clusterIdPattern) {
        throw "ClusterResourceId is not a valid Microsoft.AzureStackHCI/clusters resource ID: $ClusterResourceId"
    }
    $subscriptionId = $Matches[1]
    $resourceGroup  = $Matches[2]
    $clusterName    = $Matches[3]

    $ClusterResourceId = $ClusterResourceId.TrimEnd('/')

    try {
        $parsedMin = [System.Version]$MinVersion
    }
    catch {
        throw "MinVersion '$MinVersion' is not a valid version string."
    }

    # ---- Verify Az PowerShell context ---------------------------------------
    # 1. Az.Accounts module (>= 5.3.1) is available, then import it.
    $requiredAzAccountsVersion = [System.Version]'5.3.1'
    $azAccounts = Get-Module -ListAvailable -Name Az.Accounts |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $azAccounts) {
        throw "The 'Az.Accounts' module is required but not installed. Install it with: Install-Module Az.Accounts -MinimumVersion $requiredAzAccountsVersion -Scope CurrentUser"
    }
    if ($azAccounts.Version -lt $requiredAzAccountsVersion) {
        throw "'Az.Accounts' $($azAccounts.Version) is installed but version $requiredAzAccountsVersion or later is required. Update it with: Update-Module Az.Accounts"
    }
    Import-Module Az.Accounts -MinimumVersion $requiredAzAccountsVersion -ErrorAction Stop

    # 2. User is logged in (an Az context exists).
    $ctx = Get-AzContext
    if (-not $ctx) {
        throw "No active Az context. Run 'Connect-AzAccount' first."
    }

    # 3. Active subscription matches the one in -ClusterResourceId.
    if ($ctx.Subscription.Id -ne $subscriptionId) {
        throw "Active Az subscription '$($ctx.Subscription.Id)' ($($ctx.Subscription.Name)) does not match cluster's subscription '$subscriptionId'. Run: Set-AzContext -Subscription $subscriptionId"
    }
    Write-Host "Using Az context: subscription '$($ctx.Subscription.Name)' ($($ctx.Subscription.Id)), account '$($ctx.Account.Id)'." -ForegroundColor Cyan
    # -------------------------------------------------------------------------

    Write-Host "Fetching cluster: $ClusterResourceId" -ForegroundColor Cyan
    $cluster = Invoke-AzRestGet -Path "$ClusterResourceId`?api-version=$ClusterApiVersion"
    $region  = $cluster.location
    if ([string]::IsNullOrWhiteSpace($region)) {
        throw "Cluster $ClusterResourceId has no location set."
    }
    Write-Host "Cluster location: $region" -ForegroundColor Cyan

    $arcSettingsPath = "$ClusterResourceId/arcSettings/default?api-version=$ArcSettingsApiVersion"
    Write-Host "Fetching arc settings: $arcSettingsPath" -ForegroundColor Cyan
    $arcSettings = Invoke-AzRestGet -Path $arcSettingsPath

    $perNodeDetails = @($arcSettings.properties.perNodeDetails)
    if ($perNodeDetails.Count -eq 0) {
        throw "No perNodeDetails found on $ClusterResourceId/arcSettings/default."
    }

    Write-Host "Found $($perNodeDetails.Count) arc machine(s)." -ForegroundColor Cyan

    $results = foreach ($node in $perNodeDetails) {
        $arcInstanceId = $node.arcInstance
        $nodeName      = $node.name
        $arcShortName  = if ($arcInstanceId) { $arcInstanceId.Split('/')[-1] } else { '<unknown>' }

        $reported = $null
        $result   = 'Fail'
        $detail   = ''

        if (-not $arcInstanceId) {
            $detail = 'perNodeDetails entry has no arcInstance'
            $reported = '<missing>'
        }
        else {
            try {
                $machine = Invoke-AzRestGet -Path "$arcInstanceId`?api-version=$ArcMachineApiVersion"
                $reported = $machine.properties.detectedProperties.$SolutionVersionKey
            }
            catch {
                $detail = $_.Exception.Message
            }

            if (-not $reported) {
                $reported = '<missing>'
                if (-not $detail) { $detail = "detectedProperties.$SolutionVersionKey not set" }
            }
            else {
                try {
                    $parsedReported = [System.Version]$reported
                    if ($parsedReported -ge $parsedMin) {
                        $result = 'Pass'
                    }
                    else {
                        $detail = "$reported < $MinVersion"
                    }
                }
                catch {
                    $detail = "Unparseable version '$reported'"
                }
            }
        }

        [pscustomobject]@{
            Node            = $nodeName
            ArcMachine      = $arcShortName
            SolutionVersion = $reported
            MinVersion      = $MinVersion
            Result          = $result
            Detail          = $detail
        }
    }

    $results | Format-Table Node, ArcMachine, SolutionVersion, MinVersion, Result, Detail -AutoSize

    $passCount = @($results | Where-Object Result -eq 'Pass').Count
    $total     = $results.Count
    $failCount = $total - $passCount

    if ($failCount -gt 0) {
        Write-Host "$passCount/$total node(s) meet MinVersion $MinVersion. $failCount failing." -ForegroundColor Yellow
        throw "Skipping EdgeMachine creation: $failCount of $total node(s) do not meet MinVersion $MinVersion."
    }

    Write-Host "All $total node(s) meet MinVersion $MinVersion." -ForegroundColor Green

    # Build the plan first so we can show the user exactly what's about to happen.
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($node in $perNodeDetails) {
        $arcInstanceId   = $node.arcInstance

        if (-not $arcInstanceId) {
            # Should be unreachable when all results are Pass, but guard anyway.
            Write-Host "Skipping perNodeDetails entry '$($node.name)': no arcInstance." -ForegroundColor Yellow
            continue
        }

        $edgeMachineName = $arcInstanceId.Split('/')[-1]

        $bodyObj = [ordered]@{
            properties = [ordered]@{
                arcMachineResourceId = $arcInstanceId
                edgeMachineKind      = 'Dedicated'
            }
            location   = $region
            identity   = [ordered]@{ type = 'SystemAssigned' }
        }
        $body = $bodyObj | ConvertTo-Json -Compress -Depth 5
        $path = "/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.azurestackhci/edgemachines/$edgeMachineName" + "?api-version=$EdgeMachineApiVersion"

        $plan.Add([pscustomobject]@{
            Name       = $edgeMachineName
            ArcMachine = $arcInstanceId
            Path       = $path
            Body       = $body
        })
    }

    if ($plan.Count -eq 0) {
        Write-Host "Nothing to create." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "The following $($plan.Count) EdgeMachine resource(s) will be created in '$resourceGroup' ($region):" -ForegroundColor Cyan
    foreach ($p in $plan) {
        Write-Host "  $($p.Name) -> $($p.ArcMachine)" -ForegroundColor Cyan
    }
    Write-Host ""

    # ShouldProcess + ConfirmImpact='High' makes this prompt by default. Pass
    # -Confirm:$false to skip the prompt, or -WhatIf to print and stop.
    $target = "$($plan.Count) EdgeMachine resource(s) in '$resourceGroup' for cluster '$clusterName'"
    if (-not $PSCmdlet.ShouldProcess($target, 'Create EdgeMachines')) {
        Write-Host "Skipped EdgeMachine creation." -ForegroundColor Yellow
        return
    }

    foreach ($p in $plan) {
        Write-Host "PUT $($p.Name) -> $($p.ArcMachine)" -ForegroundColor Cyan
        $response = Invoke-AzRestPut -Path $p.Path -Body $p.Body
        if ($response) {
            Write-Verbose "Response: $response"
        }
    }

    Write-Host "Done. Created/updated $($plan.Count) EdgeMachine resource(s) for cluster '$clusterName'." -ForegroundColor Green
}

Export-ModuleMember -Function New-EdgeMachinesForCluster
