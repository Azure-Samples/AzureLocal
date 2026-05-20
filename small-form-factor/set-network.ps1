<#
.SYNOPSIS
Creates an internal Hyper-V switch, enables NAT to the PC's internet connection, and provides DHCP.

.DESCRIPTION
- Default mode (Windows Client): Uses Internet Connection Sharing (ICS) to share the active internet adapter to the internal Hyper-V switch.

  ICS supplies both NAT and DHCP (subnet is 192.168.137.0/24 and is managed by ICS).

- Windows Server mode (-Mode WinNAT): Creates a WinNAT with a configurable prefix and installs/configures the DHCP Server role.

.PARAMETER SwitchName
Name of the internal Hyper-V switch to create/use.

.PARAMETER Mode
'ICS' (default; recommended on Windows client) or 'WinNAT' (recommended on Windows Server).

.PARAMETER SubnetPrefix
IPv4 prefix for the internal network (CIDR). Used only in WinNAT mode.
Example: 192.168.200.0/24

.PARAMETER Gateway
Gateway IP address on the host-side vEthernet for WinNAT mode.
Example: 192.168.200.1

.PARAMETER NatName
Name to assign to the WinNAT (WinNAT mode only).

.PARAMETER DnsServers
DNS servers to hand out via DHCP scope (WinNAT mode only).

.PARAMETER ExternalIfAlias
Optional. Override the automatically detected internet adapter (by default-route) if needed.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SwitchName = "HV-Internal-NAT",

    [ValidateSet("ICS", "WinNAT")]
    [string]$Mode = "ICS",

    [string]$SubnetPrefix = "192.168.200.0/24",

    [string]$Gateway = "192.168.200.1",

    [string]$NatName = "HV-Internal-NAT",

    [string[]]$DnsServers = @("1.1.1.1", "8.8.8.8"),

    [string]$ExternalIfAlias
)

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()

    return (
        [System.Security.Principal.WindowsPrincipal]$id
    ).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-IsAdmin)) {
    throw "Run this script from an elevated PowerShell (Run as administrator)."
}

# Ensure Hyper-V module/cmdlets exist
if (-not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) {
    throw "Hyper-V PowerShell cmdlets not found. Enable Hyper-V and PowerShell tools first."
}

Write-Host "==> Ensuring internal Hyper-V switch exists: $SwitchName"

$sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue

if (-not $sw) {
    $sw = New-VMSwitch `
        -Name $SwitchName `
        -SwitchType Internal `
        -Notes "Internal switch for NAT+DHCP"
}
elseif ($sw.SwitchType -ne "Internal") {
    throw "A Hyper-V switch named '$SwitchName' already exists, but it is '$($sw.SwitchType)' instead of 'Internal'. Choose a different -SwitchName or remove the conflicting switch."
}
else {
    Write-Host "==> Reusing existing internal Hyper-V switch '$SwitchName'."
}

$internalIfAlias = "vEthernet ($SwitchName)"

# Wait for the host vNIC to show up
$timeout = (Get-Date).AddSeconds(20)

while (
    -not (Get-NetAdapter -InterfaceAlias $internalIfAlias -ErrorAction SilentlyContinue) `
    -and (Get-Date) -lt $timeout
) {
    Start-Sleep -Seconds 1
}

$internalAdapter = Get-NetAdapter `
    -InterfaceAlias $internalIfAlias `
    -ErrorAction Stop

# Detect the external (internet) adapter by default route unless overridden
if ([string]::IsNullOrWhiteSpace($ExternalIfAlias)) {

    $defaultRoute = Get-NetRoute `
        -DestinationPrefix "0.0.0.0/0" `
        -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric, InterfaceMetric |
        Select-Object -First 1

    if (-not $defaultRoute) {
        throw "Couldn't detect a default route. Specify -ExternalIfAlias explicitly."
    }

    $ExternalIfAlias = (
        Get-NetIPInterface `
            -InterfaceIndex $defaultRoute.InterfaceIndex `
            -AddressFamily IPv4
    ).InterfaceAlias
}

$externalAdapter = Get-NetAdapter `
    -InterfaceAlias $ExternalIfAlias `
    -ErrorAction Stop

Write-Host "==> External (internet) adapter: $ExternalIfAlias"

# Helper: enable ICS between external and internal adapters
function Enable-ICS {

    param(
        [string]$PublicIfAlias,
        [string]$PrivateIfAlias
    )

    Write-Host "==> Enabling ICS (NAT+DHCP) from '$PublicIfAlias' to '$PrivateIfAlias'..."

    $netShare = New-Object -ComObject HNetCfg.HNetShare

    # Build a map of connection name -> INetConnection
    $connections = @()
    $enum = $netShare.EnumEveryConnection()

    foreach ($conn in $enum) {
        $connections += $conn
    }

    function Get-Conn([string]$alias) {

        foreach ($c in $connections) {
            $p = $netShare.NetConnectionProps($c)

            if ($p.Name -eq $alias) {
                return $c
            }
        }

        return $null
    }

    $pubConn  = Get-Conn $PublicIfAlias
    $privConn = Get-Conn $PrivateIfAlias

    if (-not $pubConn) {
        throw "ICS: couldn't find public connection '$PublicIfAlias' in HNet list."
    }

    if (-not $privConn) {
        throw "ICS: couldn't find private connection '$PrivateIfAlias' in HNet list."
    }

    $pubCfg  = $netShare.INetSharingConfigurationForINetConnection($pubConn)
    $privCfg = $netShare.INetSharingConfigurationForINetConnection($privConn)

    # 0 = Public (shared to), 1 = Private (receives)
    $publicSharingType = 0
    $privateSharingType = 1

    $publicAlreadyConfigured = $pubCfg.SharingEnabled -and $pubCfg.SharingConnectionType -eq $publicSharingType
    $privateAlreadyConfigured = $privCfg.SharingEnabled -and $privCfg.SharingConnectionType -eq $privateSharingType

    if ($publicAlreadyConfigured -and $privateAlreadyConfigured) {
        Write-Host "==> ICS is already configured for '$PublicIfAlias' -> '$PrivateIfAlias'."
        return
    }

    # Disable only the target adapters before applying the desired state. This makes repeat runs converge without
    # tearing down unrelated sharing settings unless they conflict with this setup.
    if ($pubCfg.SharingEnabled) {
        $pubCfg.DisableSharing()
    }

    if ($privCfg.SharingEnabled) {
        $privCfg.DisableSharing()
    }

    $pubCfg.EnableSharing($publicSharingType)
    $privCfg.EnableSharing($privateSharingType)

    Write-Host "==> ICS enabled. Note: ICS will set '$PrivateIfAlias' to 192.168.137.1/24 and provide DHCP on 192.168.137.0/24."
}

# Helper: CIDR -> dotted decimal subnet mask
function Get-SubnetMaskFromCidr {

    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 32)]
        [int]$Cidr
    )

    if ($Cidr -eq 0) {
        return "0.0.0.0"
    }

    $mask32 = ([uint32]0xFFFFFFFF) - (([uint32]1 -shl (32 - $Cidr)) - 1)

    $octets = @(
        ($mask32 -shr 24) -band 0xFF
        ($mask32 -shr 16) -band 0xFF
        ($mask32 -shr 8)  -band 0xFF
        $mask32 -band 0xFF
    )

    return ($octets -join '.')
}

# Helper: configure WinNAT + DHCP Server (Windows Server)
function Configure-WinNAT-AndDHCP {

    param(
        [string]$InternalIfAlias,
        [string]$SubnetPrefix,
        [string]$Gateway,
        [string]$NatName,
        [string[]]$DnsServers
    )

    Write-Host "==> Configuring static IP $Gateway on $InternalIfAlias"

    # Remove any existing IPv4 on that adapter within the same prefix
    $existing = Get-NetIPAddress `
        -InterfaceAlias $InternalIfAlias `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue

    foreach ($ip in $existing) {

        # Remove conflicting IPs
        if ($ip.IPAddress -ne $Gateway) {
            Remove-NetIPAddress `
                -InterfaceAlias $InternalIfAlias `
                -IPAddress $ip.IPAddress `
                -Confirm:$false `
                -ErrorAction Stop
        }
    }

    # Add desired IP if not present
    if (-not ($existing | Where-Object { $_.IPAddress -eq $Gateway })) {

        $prefixLen = [int]($SubnetPrefix -split '/')[1]

        New-NetIPAddress `
            -InterfaceAlias $InternalIfAlias `
            -IPAddress $Gateway `
            -PrefixLength $prefixLen `
            -Type Unicast | Out-Null
    }

    # WinNAT: converge on the desired name and prefix.
    $existingNat = @(Get-NetNat -ErrorAction SilentlyContinue)
    $natByName = $existingNat | Where-Object { $_.Name -eq $NatName } | Select-Object -First 1
    $natByPrefix = $existingNat | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $SubnetPrefix } | Select-Object -First 1

    if ($natByName -and $natByName.InternalIPInterfaceAddressPrefix -ne $SubnetPrefix) {
        Write-Host "==> Recreating WinNAT '$NatName' with prefix $SubnetPrefix"

        Remove-NetNat `
            -Name $NatName `
            -Confirm:$false `
            -ErrorAction Stop

        $natByName = $null
    }

    if (-not $natByName -and $natByPrefix -and $natByPrefix.Name -ne $NatName) {
        Write-Host "==> Replacing WinNAT '$($natByPrefix.Name)' with '$NatName' on $SubnetPrefix"

        Remove-NetNat `
            -Name $natByPrefix.Name `
            -Confirm:$false `
            -ErrorAction Stop

        $natByPrefix = $null
    }

    $conflictingNat = $existingNat |
        Where-Object {
            $_.Name -ne $NatName `
            -and $_.InternalIPInterfaceAddressPrefix -ne $SubnetPrefix
        } |
        Select-Object -First 1

    if ($conflictingNat) {
        throw "Another NAT ('$($conflictingNat.Name)' on '$($conflictingNat.InternalIPInterfaceAddressPrefix)') already exists on this host. Remove it or rerun this script with matching -NatName and -SubnetPrefix values."
    }

    $natByName = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue

    if (-not $natByName) {
        Write-Host "==> Creating WinNAT '$NatName' on $SubnetPrefix"

        New-NetNat `
            -Name $NatName `
            -InternalIPInterfaceAddressPrefix $SubnetPrefix | Out-Null
    }
    else {
        Write-Host "==> Reusing existing WinNAT '$NatName' on $SubnetPrefix"
    }

    # Install and configure DHCP Server
    Write-Host "==> Installing DHCP role (if available) and creating scope"

    $serverOs = (
        Get-CimInstance -ClassName Win32_OperatingSystem
    ).ProductType

    # 1=Workstation, 2=DomainController, 3=Server
    if ($serverOs -eq 1) {
        throw "DHCP Server role is not available on Windows client. Use -Mode ICS instead."
    }

    Import-Module ServerManager -ErrorAction SilentlyContinue

    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {

        $dhcp = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue

        if (-not $dhcp -or -not $dhcp.Installed) {

            Install-WindowsFeature `
                -Name DHCP `
                -IncludeManagementTools `
                -ErrorAction Stop | Out-Null
        }
    }
    else {
        throw "ServerManager module not found. Run on Windows Server or use -Mode ICS."
    }

    # Compute network and mask for netsh
    $net  = ($SubnetPrefix -split '/')[0]
    $cidr = [int]($SubnetPrefix -split '/')[1]

    $mask = Get-SubnetMaskFromCidr -Cidr $cidr

    # DHCP pool: x.50 - x.200
    $base = [System.Net.IPAddress]::Parse($net).GetAddressBytes()

    $poolStart = [byte[]]$base.Clone()
    $poolStart[3] = 50

    $poolEnd = [byte[]]$base.Clone()
    $poolEnd[3] = 200

    $startIp = ($poolStart -join '.')
    $endIp   = ($poolEnd -join '.')

    $scopeName = "HV-Internal-$SwitchName"

    Import-Module DhcpServer -ErrorAction Stop

    $scope = Get-DhcpServerv4Scope `
        -ScopeId $net `
        -ErrorAction SilentlyContinue

    $scopeNeedsRecreate = $false

    if ($scope) {
        $scopeNeedsRecreate = `
            $scope.StartRange.IPAddressToString -ne $startIp `
            -or $scope.EndRange.IPAddressToString -ne $endIp `
            -or $scope.SubnetMask.IPAddressToString -ne $mask
    }

    if ($scopeNeedsRecreate) {
        Write-Host "==> Recreating DHCP scope $net with range $startIp - $endIp"

        Remove-DhcpServerv4Scope `
            -ScopeId $net `
            -Force `
            -ErrorAction Stop

        $scope = $null
    }

    if (-not $scope) {
        Write-Host "==> Creating DHCP scope $scopeName $net $mask ($startIp - $endIp)"

        Add-DhcpServerv4Scope `
            -Name $scopeName `
            -StartRange $startIp `
            -EndRange $endIp `
            -SubnetMask $mask `
            -State Active `
            -ErrorAction Stop | Out-Null
    }
    else {
        Write-Host "==> Updating existing DHCP scope $net"

        Set-DhcpServerv4Scope `
            -ScopeId $net `
            -Name $scopeName `
            -State Active `
            -ErrorAction Stop | Out-Null
    }

    Set-DhcpServerv4OptionValue `
        -ScopeId $net `
        -Router $Gateway `
        -DnsServer $DnsServers `
        -ErrorAction Stop

    # Optional: attempt DHCP authorization in AD if domain-joined
    try {

        Add-DhcpServerInDC `
            -DnsName $env:COMPUTERNAME `
            -IpAddress (
                Get-NetIPAddress -AddressFamily IPv4 |
                Select-Object -First 1 -ExpandProperty IPAddress
            ) `
            -ErrorAction Stop | Out-Null

        Write-Host "==> DHCP server authorized in AD (if applicable)."
    }
    catch {
        Write-Host "==> Skipping AD DHCP authorization (not required or not applicable)."
    }
}

# Main flow
if ($Mode -eq "ICS") {

    Enable-ICS `
        -PublicIfAlias $ExternalIfAlias `
        -PrivateIfAlias $internalIfAlias

    Write-Host ""
    Write-Host "All set! Attach your VMs to switch '$SwitchName'."
    Write-Host "They will receive DHCP from ICS (usually 192.168.137.0/24) and reach the internet via NAT."
}
else {

    Write-Host "==> WinNAT mode selected. Using SubnetPrefix=$SubnetPrefix, Gateway=$Gateway, NatName=$NatName"

    Configure-WinNAT-AndDHCP `
        -InternalIfAlias $internalIfAlias `
        -SubnetPrefix $SubnetPrefix `
        -Gateway $Gateway `
        -NatName $NatName `
        -DnsServers $DnsServers

    Write-Host ""
    Write-Host "All set! Attach your VMs to switch '$SwitchName'."
    Write-Host "They will receive DHCP from the host and access the internet via WinNAT."
}