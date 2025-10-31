<#
.SYNOPSIS
  Installs and configures the Databricks Terraform provider for Windows hosts.

.DESCRIPTION
    - Resolves the requested Databricks provider version (defaults to the latest published release).
    - Downloads and verifies the provider archive using Terraform Registry metadata (GitHub releases).
  - Installs the provider binary into C:\ProgramData\terraform.d\plugins for system-wide use.
  - OPTIONAL: Configures DATABRICKS_HOST and DATABRICKS_TOKEN environment variables.
  - Provides guidance for Terraform to consume the freshly installed provider.

.PARAMETER Version
  Databricks provider version (for example: 1.36.1). Use 'latest' to auto-resolve.

.PARAMETER InstallRoot
  Root directory for provider plugins. Defaults to C:\ProgramData\terraform.d\plugins.

.PARAMETER Force
  Reinstall even if the requested provider version is already present.

.PARAMETER ConfigureEnvironment
  When supplied, the script will set Databricks environment variables after installation.

.PARAMETER DatabricksHost
  Optional Databricks workspace URL (e.g. https://adb-12345.6.azuredatabricks.net). Required when ConfigureEnvironment is set and no host is provided interactively.

.PARAMETER DatabricksToken
  Optional Databricks personal access token. If not supplied, you will be prompted when ConfigureEnvironment is set.

.PARAMETER EnvironmentScope
  Scope for the Databricks environment variables (Machine, User, or Process). Defaults to User.

.EXAMPLE
  .\databricks-td-provider-setup.ps1
  Installs the latest provider for all users.

.EXAMPLE
  .\databricks-td-provider-setup.ps1 -Version 1.36.1 -ConfigureEnvironment -EnvironmentScope Machine
  Installs provider version 1.36.1 and configures machine-scoped Databricks variables.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$Version = 'latest',
    [string]$InstallRoot = 'C:\ProgramData\terraform.d\plugins',
    [switch]$Force,
    [switch]$ConfigureEnvironment,
    [string]$DatabricksHost,
    [System.Security.SecureString]$DatabricksToken,
    [ValidateSet('Machine', 'User', 'Process')][string]$EnvironmentScope = 'User'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:WhatIfActive = $PSBoundParameters.ContainsKey('WhatIf') -or $WhatIfPreference

try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
} catch {
    Write-Warning "Failed to enforce TLS 1.2+: $($_.Exception.Message)"
}

function Resolve-DatabricksProviderVersion {
    param([string]$RequestedVersion)

    if ([string]::IsNullOrWhiteSpace($RequestedVersion) -or $RequestedVersion -eq 'latest') {
        Write-Verbose 'Resolving latest Databricks provider version from registry.terraform.io'
        try {
            $response = Invoke-RestMethod -Uri 'https://registry.terraform.io/v1/providers/databricks/databricks/versions' -UseBasicParsing
            $latest = $response.versions | Sort-Object { [version]$_.version } -Descending | Select-Object -First 1
            if (-not $latest.version) {
                throw "Latest version not returned by registry API."
            }
            return $latest.version
        } catch {
            throw "Unable to determine latest Databricks provider version. Specify -Version explicitly. Details: $($_.Exception.Message)"
        }
    }

    if ($RequestedVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "Version '$RequestedVersion' must follow semantic versioning (e.g. 1.36.1)."
    }

    return $RequestedVersion
}

function Resolve-DatabricksProviderDownloadInfo {
    param(
        [string]$Version,
        [string]$OsSegment,
        [string]$ArchSegment
    )

    $uri = "https://registry.terraform.io/v1/providers/databricks/databricks/$Version/download/$OsSegment/$ArchSegment"
    Write-Verbose "Resolving Databricks provider download metadata from $uri"

    try {
        $response = Invoke-RestMethod -Uri $uri -UseBasicParsing -ErrorAction Stop
    } catch {
        throw "Failed to resolve download metadata for Databricks provider $Version ($OsSegment/$ArchSegment). Details: $($_.Exception.Message)"
    }

    if (-not $response.download_url) {
        throw "Download metadata for Databricks provider $Version did not include a download_url."
    }

    return $response
}

function Get-ProviderTargetPath {
    param(
        [string]$Root,
        [string]$Version,
        [string]$OsSegment,
        [string]$ArchSegment
    )

    $providerNamespace = 'registry.terraform.io'
    $providerOrg = 'databricks'
    $providerName = 'databricks'

    return Join-Path $Root (Join-Path $providerNamespace (Join-Path $providerOrg (Join-Path $providerName (Join-Path $Version "${OsSegment}_${ArchSegment}"))))
}

function Get-NormalizedFullPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($resolved) {
        return $resolved.Path
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($script:WhatIfActive) {
            Write-Host "WhatIf: Would create directory $Path" -ForegroundColor Yellow
        } else {
            Write-Verbose "Creating directory $Path"
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
}

function Download-File {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not $PSCmdlet.ShouldProcess($Destination, "Download $Uri")) {
        return
    }

    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -ErrorAction Stop
}

function Get-ExpectedChecksum {
    param(
        [string]$ChecksumFile,
        [string]$ArchiveFileName
    )

    foreach ($line in Get-Content -LiteralPath $ChecksumFile) {
        if ($line -match "^([0-9a-f]{64})\s+\*?$ArchiveFileName$") {
            return $Matches[1]
        }
    }

    throw "Checksum for $ArchiveFileName was not found in $ChecksumFile."
}

function Assert-FileHashMatches {
    param(
        [string]$Path,
        [string]$ExpectedHash
    )

    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedHash.ToLowerInvariant()) {
        throw "Checksum verification failed for $Path. Expected $ExpectedHash, got $actual."
    }
}

function Install-DatabricksProvider {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Version,
        [string]$InstallDirectory,
        [string]$OsSegment,
        [string]$ArchSegment,
        [switch]$Force
    )

    $downloadInfo = Resolve-DatabricksProviderDownloadInfo -Version $Version -OsSegment $OsSegment -ArchSegment $ArchSegment

    $archiveName = $downloadInfo.filename
    $checksumName = Split-Path -Path $downloadInfo.shasums_url -Leaf
    $providerBinaryName = "terraform-provider-databricks_v${Version}.exe"

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("databricks-provider-" + [System.Guid]::NewGuid().ToString())
    $archivePath = Join-Path $tempRoot $archiveName
    $checksumPath = Join-Path $tempRoot $checksumName

    try {
        Ensure-Directory -Path $tempRoot

        Download-File -Uri $downloadInfo.download_url -Destination $archivePath
        Download-File -Uri $downloadInfo.shasums_url -Destination $checksumPath

        if ($script:WhatIfActive -and (-not (Test-Path -LiteralPath $archivePath))) {
            Write-Host "WhatIf: Skipping archive validation and extraction for $archiveName." -ForegroundColor Yellow
            return
        }

        $expectedHash = Get-ExpectedChecksum -ChecksumFile $checksumPath -ArchiveFileName $archiveName
        Assert-FileHashMatches -Path $archivePath -ExpectedHash $expectedHash

        if (Test-Path -LiteralPath $InstallDirectory) {
            if ($Force) {
                if ($PSCmdlet.ShouldProcess($InstallDirectory, "Remove existing provider")) {
                    Remove-Item -LiteralPath $InstallDirectory -Recurse -Force -ErrorAction Stop
                }
            } else {
                $existingBinary = Get-ChildItem -LiteralPath $InstallDirectory -Filter 'terraform-provider-databricks*' -ErrorAction SilentlyContinue
                if ($existingBinary) {
                    Write-Host "Databricks provider $Version already present at $InstallDirectory. Use -Force to reinstall." -ForegroundColor Green
                    return
                }
            }
        }

        Ensure-Directory -Path $InstallDirectory

        if ($PSCmdlet.ShouldProcess($InstallDirectory, "Extract $archiveName")) {
            Expand-Archive -Path $archivePath -DestinationPath $InstallDirectory -Force
        }

        $expectedBinaryPath = Join-Path $InstallDirectory $providerBinaryName
        if (-not (Test-Path -LiteralPath $expectedBinaryPath)) {
            $downloadedBinary = Get-ChildItem -LiteralPath $InstallDirectory -Filter 'terraform-provider-databricks*' | Select-Object -First 1
            if ($downloadedBinary) {
                Rename-Item -LiteralPath $downloadedBinary.FullName -NewName $providerBinaryName -Force
            }
        }

        Write-Host "Databricks provider $Version installed to $InstallDirectory" -ForegroundColor Green
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-DatabricksEnvironmentVariables {
    param(
        [string]$Host,
        [System.Security.SecureString]$Token,
        [System.EnvironmentVariableTarget]$Scope
    )

    if ([string]::IsNullOrWhiteSpace($Host)) {
        $Host = Read-Host 'Enter DATABRICKS_HOST (e.g. https://adb-<workspace>.azuredatabricks.net)'
    }

    if (-not $Token) {
        $Token = Read-Host 'Enter DATABRICKS_TOKEN' -AsSecureString
    }

    if (-not $Token) {
        throw "Databricks token input is required."
    }

    $tokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringUni($tokenPtr)

    try {
        [Environment]::SetEnvironmentVariable('DATABRICKS_HOST', $Host, $Scope)
        [Environment]::SetEnvironmentVariable('DATABRICKS_TOKEN', $plainToken, $Scope)

        if ($Scope -eq [EnvironmentVariableTarget]::Process) {
            $env:DATABRICKS_HOST = $Host
            $env:DATABRICKS_TOKEN = $plainToken
        }

        Write-Host "Environment variables configured (scope: $Scope)." -ForegroundColor Green
    } finally {
        if ($tokenPtr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr)
        }
    }
}

$resolvedInstallRoot = Get-NormalizedFullPath -Path $InstallRoot
if (-not $resolvedInstallRoot) {
    throw "Install root '$InstallRoot' could not be resolved."
}

Ensure-Directory -Path $resolvedInstallRoot

$resolvedVersion = Resolve-DatabricksProviderVersion -RequestedVersion $Version
Write-Host "Target Databricks provider version: $resolvedVersion" -ForegroundColor Cyan

$osSegment = 'windows'
$archSegment = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
$targetPath = Get-ProviderTargetPath -Root $resolvedInstallRoot -Version $resolvedVersion -OsSegment $osSegment -ArchSegment $archSegment

Install-DatabricksProvider -Version $resolvedVersion -InstallDirectory $targetPath -OsSegment $osSegment -ArchSegment $archSegment -Force:$Force

try {
    $terraformCmd = Get-Command terraform -ErrorAction Stop
    Write-Host "Terraform command resolved to: $($terraformCmd.Source)" -ForegroundColor Gray
} catch {
    Write-Warning "Terraform executable not found on PATH. Ensure Terraform is installed before using the provider."
}

if ($ConfigureEnvironment) {
    if ($script:WhatIfActive) {
        Write-Host "WhatIf: Would configure Databricks environment variables (scope: $EnvironmentScope)." -ForegroundColor Yellow
    } else {
        $scope = [EnvironmentVariableTarget]::$EnvironmentScope
        Set-DatabricksEnvironmentVariables -Host $DatabricksHost -Token $DatabricksToken -Scope $scope
        Write-Host "Restart any open shells or CI agents to pick up environment changes." -ForegroundColor Yellow
    }
}

Write-Host "`nDatabricks provider setup complete." -ForegroundColor Yellow
Write-Host "Provider directory: $targetPath"
Write-Host "Mirror example: terraform providers mirror C:\\terraform-mirror" -ForegroundColor Gray
Write-Host "Test command: terraform init -upgrade" -ForegroundColor Gray
