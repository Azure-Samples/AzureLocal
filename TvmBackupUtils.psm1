<###################################################
#                                                 #
#  Copyright (c) Microsoft. All rights reserved.  #
#                                                 #
##################################################>


<#
#Usage:
#############################################
# Backup the Tvm Vault

# Step 1: On a secure computer using PowerShell 7 generate a wrapping key.
$rsa = [System.Security.Cryptography.RSA]::Create(2048)  #Note the key size for later.
$privateKeyPem = $rsa.ExportPkcs8PrivateKeyPem()
$privateKeyPem | Out-File -FilePath .\private.pem
$publicKeyPem = $rsa.ExportRSAPublicKeyPem()
$publicKeyPem | Out-File -FilePath .\public.pem

# Step 2: Copy the .\public.pem file to your cluster.

# Step 3: Backup the TVM keys on your cluster
import-module .\TvmBackupUtils.psm1 -force
Backup-TVMKeys -WrappingKeyPath <path to public.pem> -BackupRootPath <path to backup root folder where the timestamped backup folder will be stored>

# Step 4: Make note of the time stamped backup folder created under the backup root folder.

##############################################
# Restore on a new cluster

# Step 1: Copy both private and public key files to the new cluster as well as the time stamped backup folder. DO NOT MODIFY THE BACKUP FOLDER!

# Step 2: Import the wrapping key you created for the backup
# Important: The WrappingKeyName CANNOT match the name of a key existing in the backup. This will cause collisions during import.
Import-Module .\TvmBackupUtils.psm1 -force
Import-TvmWrappingKeyFromPem -KeyName <WrappingKeyName> -PublicKeyPath <path to public.pem> -PrivateKeyPath <path to private.pem> -KeySize 2048

# Restore the keys from backup
Import-TVMKeys -WrappingKeyName  <WrappingKeyName> -BackupPath <path to timestamped backup folder>

# Important: Delete public.pem and private.pem from the machine.
# Remove the "Wrapping Key" from the vault using Remove-MocKey (to avoid collisions later), failure to do so may lead to issues.

#Important Note:
This script assumes the vault will be empty. You will receive an InvalidVersion error if a key of the same name exists in the vault already. If your goal is to recover a single or select set of TVM instances, you can ignore InvalidVersion errors for those TVM keys you don't care about.
If a TVM is created in the new instance prior to re-importing the keys (from the backup), we will automatically create the AzureStackTvmAKRootKey. This will trigger a collision. You should delete this key prior to re-importing to make sure attestation continues to work.

#>

# Moc Stack Object names
$script:groupName = "AzureStackHostAttestation"
$script:keyvaultName = "AzureStackTvmKeyVault"
$script:requiredMocPSVersion = [System.Version]::Parse("1.2.27")
$script:requiredMocStackVersion = [System.Version]::Parse("1.14.1.10414")

<#
.SYNOPSIS
   Create a Backup of all Keys in the TVM Moc Vault
.DESCRIPTION
    Creates a backup of the the keys currently residing in the Moc Key Vault for TVM.
    This back up is a point in time. The results will be store in a timestamped folder.
.PARAMETER WrappingKeyPath
    Path to a the Public Key to be used for wrapping the keys. You must control the private key to re-import.
.PARAMETER BackupRootPath
    Path to the backup root folder where the timestamped backup folder containing the backup files will be stored.
.NOTES
    Do not modify the folder structure of the backup or file names. 
#>
function Backup-TVMKeys 
{
    param (
        [Parameter(Mandatory=$true)]
        [string] $WrappingKeyPath,

        [Parameter(Mandatory=$true)]
        [string] $BackupRootPath
    )

    #Check Moc Powershell version
    try
    {
        $installedVersion = [System.Version]::Parse((get-mocconfig).moduleVersion)
    }
    catch
    {
        throw "Unable to determine Moc installation versions."
    }

    if ($installedVersion -lt $script:requiredMocPSVersion)
    {
        throw "Incompatible moc powershell version: $installedVersion found. Version $script:requiredMocPSVersion is needed. Please update your cluster."
    }

    #Generate a folder based on the current time so multiple backups can be taken.
    try 
    {
        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $timestampPath = Join-Path -Path $BackupRootPath -ChildPath $timestamp
        $rsaBackupPath = Join-Path -Path $timestampPath -ChildPath "RSA"
        $aesBackupPath = Join-Path -Path $timestampPath -ChildPath "AES"
       
        New-Item -Path $timestampPath -ItemType Directory -Force | Out-Null
        New-Item -Path $rsaBackupPath -ItemType Directory -Force | Out-Null
        New-Item -Path $aesBackupPath -ItemType Directory -Force | Out-Null

    }
    catch 
    {
        Write-Error "An error occurred while creating backup directories or generating wrapping key pair: $_"
        throw $_
    }
    
    
    Write-host "Backing up TVM Vault keys to $timestampPath"

    #Get all the keys in our vault
    $keys = Get-MocKey -group $script:groupName -keyvaultName $script:keyvaultName
    foreach ($key in $keys) 
    {
        #extract key properties
        try 
        {
            $keyName = $key.Name
            $keyType = $key.properties.kty
            $keysize = $key.properties.key_size
        }
        catch 
        {
            Write-Error "An error occurred while processing key $_"
            throw $_
        }

        #hack hack, embed keyname and size in the name for later.
        $outfilename = $keyName +'_'+ $keysize +'.json'

        if ($keyType -eq "AES") 
        {
            Write-Host "Backing up key $keyName to AES folder"
            $outfileFullPath = Join-Path -Path $aesBackupPath -ChildPath $outfilename 
            Export-MocKey -name $keyName  -wrappingPubKeyFile $WrappingKeyPath -outFile $outfileFullPath -group $script:groupName -keyvaultName $script:keyvaultName -size $keysize
        }
        elseif ($keyType -eq "RSA") {
            $outfileFullPath = Join-Path -Path $rsaBackupPath -ChildPath $outfilename 
            Write-Host "Backing up key $keyName to RSA folder"
            Export-MocKey -name $keyName  -wrappingPubKeyFile $WrappingKeyPath -outFile $outfileFullPath -group $script:groupName -keyvaultName $script:keyvaultName -size $keysize
        }
    }
    
}
Export-ModuleMember -Function Backup-TVMKeys 

<#
.SYNOPSIS
   Restores a previously taken backup to the moc vault. 
.DESCRIPTION
    Restores a previously taken back up to the TVM Moc Vault.
    Note that the wrapping key used to take the backup must exist in the vault to be restored
.PARAMETER BackupPath
    The path to the timestamped backup folder where the backup files are stored.
.PARAMETER WrappingKeyName
    Name of the wrapping key used in the backup residing in this vault. This key can be imported from a Pem File (see documentation)
.NOTES
    This function assumes the vault is empty. However if a key fails to import, we will continue.
    
    The previously taken backup cannot contain a key of the same name as the "WrappingKeyName", otherwise MOC command may hang.
#>

function Import-TVMKeys 
{
    param (
        [Parameter(Mandatory=$true)]
        [string] $BackupPath,

        [Parameter(Mandatory=$true)]
        [string] $WrappingKeyName

    )
    
    try
    {
        #Check Moc Powershell version
        $installedVersion = [System.Version]::Parse((get-mocconfig).moduleVersion)
    }
    catch
    {
        throw "Unable to determine Moc installation versions."
    }
    if ($installedVersion -lt $script:requiredMocPSVersion)
    {
        throw "Incompatible moc powershell version: $installedVersion found. Version $script:requiredMocPSVersion is needed. Please update your cluster."
    }


    $rsaBackupPath = Join-Path -Path $BackupPath -ChildPath "RSA"
    $aesBackupPath = Join-Path -Path $BackupPath -ChildPath "AES"

    Write-host "Importing TVM  keys from $BackupPath"

    # Iterate over all the files in aesRestorePPath
    $aesFiles = Get-ChildItem -Path $aesBackupPath -Filter *.json
    foreach ($file in $aesFiles) 
    {
        try 
        {
            $fileName = $file.Name
            $fileNameParts = $fileName -split '_'
            $keyName = $fileNameParts[0]
            $keySize = [int]($fileNameParts[1] -replace '.json', '')
            $fullFilePath = Join-Path -Path $aesBackupPath -ChildPath $fileName
        }
        catch 
        {
            Write-Error "An error occurred while processing file: $_"
            throw $_
        }

        Write-Host "Importing key $keyName with size $keySize from AES folder path = $fullFilePath"
        try
        {
            Import-MocKey -name $keyName -wrappingKeyName $WrappingKeyName -importKeyFile  $fullFilePath -group $script:groupName -keyvaultName $script:keyvaultName -size $keySize  -Type AES
        }      
        catch 
        {
            Write-Error "Error Importing Key: $_"
        }
     }
    
    # Iterate over all the files in rsaBackupPath
    $rsaFiles = Get-ChildItem -Path $rsaBackupPath -Filter *.json
    foreach ($file in $rsaFiles) 
    {
        try 
        {
            $fileName = $file.Name
            $fileNameParts = $fileName -split '_'
            $keyName = $fileNameParts[0]
            $keySize = [int]($fileNameParts[1] -replace '.json', '')
            $fullFilePath = Join-Path -Path $rsaBackupPath -ChildPath $fileName
        }
        catch 
        {
            Write-Error "An error occurred while processing file: $_"
            throw $_
        }

        Write-Host "Importing key $keyName with size $keySize from RSA folder path = $fullFilePath"
        try
        {
            Import-MocKey -name $keyName -wrappingKeyName $WrappingKeyName -importKeyFile $fullFilePath -group $script:groupName -keyvaultName $script:keyvaultName -size $keySize -type RSA
        }
        catch 
        {
            Write-Error "Error Importing Key: $_"
        }
    }

} 
Export-ModuleMember -Function  Import-TVMKeys
    
<#
.SYNOPSIS
   Generates the Json File to import a Key from a PEM into the moc vault. 

.DESCRIPTION
    Generates the Json File to import a Key from a PEM into the moc vault.
.PARAMETER KeyName
    The name of the key to be imported.
.PARAMETER PublicKeyPath
    The path to the PEM file containing the public key.
.PARAMETER PrivateKeyPath
    The path to the PEM file containing the private key. (PKCS8)
.PARAMETER OutFilePath
    The path where the generated JSON file will be saved.
#>
function Generate-ImportJsonFromPEM
{
    param (
        [Parameter(Mandatory=$true)]
        [string] $PublicKeyPath,
        [Parameter(Mandatory=$true)]
        [string] $PrivateKeyPath,
        [Parameter(Mandatory=$true)]
        [string] $OutFilePath
        )


    $template = '{"public-key":"<PUBLIC_KEY>","private-key":"<PRIVATE_KEY>","private-key-wrapping-info":{"key-name":"","public-key":"","enc":"NO_KEY_WRAP"}}'

    $publicKey = Convert-PemToBase64Url $PublicKeyPath
    $privateKey = Convert-PemToBase64Url $PrivateKeyPath


    $jsonContent = $template    -replace "<PUBLIC_KEY>", $publicKey `
                                -replace "<PRIVATE_KEY>", $privateKey `


    # Save to a file
    $jsonContent | Out-File -FilePath $OutFilePath -Encoding Ascii
    (Get-Content -Path $OutFilePath -Raw) -replace "`r`n", "`n" | Set-Content -Path $OutFilePath -NoNewline



}
Export-ModuleMember -Function  Generate-ImportJsonFromPEM

<#
.SYNOPSIS
   Converts a PEM to Base64URl with padding.

.DESCRIPTION
    Strips the header and footer from a PEM file and converts the base64 to base64URL with Padding.

.PARAMETER PemFilePath
    The path to the PEM file that needs to be converted to Base64URL format.
#>
function Convert-PemToBase64Url {
    param (
        [Parameter(Mandatory=$true)]
        [string] $PemFilePath
    )

    # Check if the PEM file exists
    if (-not (Test-Path -Path $PemFilePath)) {
        throw "The PEM file at path '$PemFilePath' does not exist."
    }

    # Retrieve the raw PEM content
    $pemContent = Get-Content $PemFilePath 

    # Remove the header and footer lines
    $pemBodyB64 = $pemContent | Where-Object { $_ -notmatch "-----BEGIN.*KEY-----" -and $_ -notmatch "-----END.*KEY-----" }

    # Join the remaining lines into a single string
    $collapsedB64 = $pemBodyB64 -join ""

    # Convert to Base64 URL-safe format
    $urlSafeB64 = $collapsedB64 -replace "\+", "-" -replace "\/", "_"  #-replace "=", "" # We need the padding

    return $urlSafeB64
}

<#
.SYNOPSIS
    Imports a Wrapping Key to the TVM vault from a PEM file
.DESCRIPTION
    Imports a Wrapping Key to the TVM vault from a PEM file
.PARAMETER KeyName
    The name that will be used to represent the imported key in moc.
.PARAMETER PublicKeyPath
    The path to the PEM file containing the public key.
.PARAMETER PrivateKeyPath
    The path to the PEM file containing the private key. (PKCS8)
.PARAMETER Key Size
    The size of the key generated
#>
function Import-TvmWrappingKeyFromPem {
    param (
        [Parameter(Mandatory=$true)]
        [string] $KeyName,
        [Parameter(Mandatory=$true)]
        [string] $PublicKeyPath,
        [Parameter(Mandatory=$true)]
        [string] $PrivateKeyPath,
        [Parameter(Mandatory=$true)]
        [string] $KeySize
    )

    try
    {
        #verify this cluster supports Import Plaintext key import and has the right ps module that supports passing the key name
        $installedMocVersion = [System.Version]::Parse((get-mocconfig).version)
        $installedPsVersion = [System.Version]::Parse((get-mocconfig).moduleVersion)
    }
    catch
    {
        throw "Unable to determine Moc installation versions."
    }

    if ($installedMocVersion  -lt $script:requiredMocStackVersion)
    {
        throw "Incompatible moc stack version: $installedMocVersion found. $script:requiredMocStackVersion is needed. Please update your cluster."
    }

    if ($installedPsVersion -lt $script:requiredMocPSVersion)
    {
        throw "Incompatible moc powershell version: $installedPsVersion found. Version $script:requiredMocPSVersion is needed. Please update your cluster."
    }


    try 
    {
        # Generate a temporary file for the JSON output
        $tempFile = [System.IO.Path]::GetTempFileName()
        Write-Host "Generating import JSON for key $KeyName at temporary location $tempFile..."

        # Generate the JSON file for importing the key
        Generate-ImportJsonFromPEM -PublicKeyPath $PublicKeyPath -PrivateKeyPath $PrivateKeyPath -OutFilePath $tempFile

        # Import the key into the vault
        Write-Host "Importing key $KeyName into the vault..."
        Import-MocKey -name $KeyName -group $script:groupName -keyvaultName $script:keyvaultName -importKeyFile $tempFile -type RSA -size $KeySize
        Write-Host "Key $KeyName successfully imported into the vault."
    } 
    catch 
    {
        Write-Error "An error occurred: $_"
        throw $_
    } finally 
    {
        # Clean up the temporary file
        if (Test-Path $tempFile) 
        {
            Remove-Item -Path $tempFile -Force
            Write-Host "Temporary file $tempFile has been cleaned up."
        }
    }
}
Export-ModuleMember -Function Import-TvmWrappingKeyFromPem
