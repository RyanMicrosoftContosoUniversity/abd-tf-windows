<#
.SYNOPSIS
  Installs Terraform globally on Windows and optionally Azure CLI, ready for automation (e.g. Azure DevOps self-hosted agents).

.DESCRIPTION
  - Validates the session is elevated
  - Resolves the desired Terraform version (default latest) and installs into C:\Program Files\HashiCorp\Terraform
  - Registers the Terraform directory on the machine-wide PATH (and current session)
  - Verifies Terraform is callable
  - OPTIONAL: Installs Azure CLI using the official MSI and verifies availability

.PARAMETER InstallAzureCLI
  Switch to install Azure CLI after Terraform is configured.

.PARAMETER Version
  Specific Terraform version to install (defaults to 'latest').

.PARAMETER Force
  Reinstall Terraform even if the requested version is already present.

.EXAMPLE
  .\tf-setup.ps1
  .\tf-setup.ps1 -Version 1.7.5
  .\tf-setup.ps1 -InstallAzureCLI -Force
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$InstallAzureCLI,
  [string]$Version = 'latest',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$whatIfActive = $PSBoundParameters.ContainsKey('WhatIf') -or $WhatIfPreference
$terraformInstallDirectory = 'C:\Program Files\HashiCorp\Terraform'
$terraformExecutablePath = Join-Path $terraformInstallDirectory 'terraform.exe'

# -------- Preconditions ------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  if ($whatIfActive) {
    Write-Warning "Running without elevation because -WhatIf was specified. No changes will be applied."
  } else {
    Write-Error "Please run this script in an elevated PowerShell session (Run as Administrator)."
    exit 1
  }
}

try {
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
} catch {
  Write-Warning "Failed to enforce TLS 1.2+: $($_.Exception.Message)"
}

try {
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
} catch {
  Write-Warning "Unable to adjust execution policy for this process: $($_.Exception.Message)"
}

function Resolve-TerraformVersion {
  param([string]$RequestedVersion)

  if ([string]::IsNullOrWhiteSpace($RequestedVersion) -or $RequestedVersion -eq 'latest') {
    Write-Host "Resolving latest Terraform version..." -ForegroundColor Cyan
    try {
      $response = Invoke-RestMethod -Uri 'https://checkpoint-api.hashicorp.com/v1/check/terraform' -UseBasicParsing -ErrorAction Stop
      if (-not $response.current_version) {
        throw "Checkpoint API did not return a version."
      }
      return $response.current_version
    } catch {
      throw "Unable to determine the latest Terraform version automatically. Provide -Version explicitly. Details: $($_.Exception.Message)"
    }
  }

  if ($RequestedVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z\.-]+)?$') {
    throw "Terraform version '$RequestedVersion' is not in a valid semantic version format (e.g. 1.7.5)."
  }

  return $RequestedVersion
}

function Get-InstalledTerraformVersion {
  param([string]$ExecutablePath)

  if (-not (Test-Path -LiteralPath $ExecutablePath)) {
    return $null
  }

  try {
    $output = & $ExecutablePath -version 2>$null
    $firstLine = ($output -split "`n")[0]
    if ($firstLine -match 'Terraform v([\w\.-]+)') {
      return $Matches[1]
    }
  } catch {
    Write-Warning "Failed to determine installed Terraform version: $($_.Exception.Message)"
  }

  return $null
}

function Get-TerraformDownloadUri {
  param([string]$ResolvedVersion)

  $architecture = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
  return "https://releases.hashicorp.com/terraform/$ResolvedVersion/terraform_${ResolvedVersion}_windows_${architecture}.zip"
}

function Install-Terraform {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [string]$ResolvedVersion,
    [string]$InstallDirectory,
    [string]$ExecutablePath
  )

  if (-not $PSCmdlet.ShouldProcess("Terraform $ResolvedVersion", "Install or upgrade at $InstallDirectory")) {
    return $false
  }

  $downloadUri = Get-TerraformDownloadUri -ResolvedVersion $ResolvedVersion
  $workingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("terraform-" + [System.Guid]::NewGuid().ToString())
  $zipPath = Join-Path $workingRoot 'terraform.zip'
  $extractPath = Join-Path $workingRoot 'extract'

  try {
    New-Item -ItemType Directory -Path $workingRoot -Force | Out-Null

    Write-Host "Downloading Terraform $ResolvedVersion..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $downloadUri -OutFile $zipPath -UseBasicParsing -ErrorAction Stop

    Write-Host "Extracting Terraform archive..." -ForegroundColor Cyan
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop

    $extractedExe = Join-Path $extractPath 'terraform.exe'
    if (-not (Test-Path -LiteralPath $extractedExe)) {
      throw "Extracted archive did not contain terraform.exe."
    }

    if (-not (Test-Path -LiteralPath $InstallDirectory)) {
      New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
    }

    Copy-Item -Path $extractedExe -Destination $ExecutablePath -Force -ErrorAction Stop
    return $true
  } finally {
    if (Test-Path -LiteralPath $workingRoot) {
      Remove-Item -LiteralPath $workingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-NormalizedPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $Path
  }

  try {
    if (Test-Path -LiteralPath $Path) {
      return (Get-Item -LiteralPath $Path).FullName.TrimEnd('\\')
    }

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\\')
  } catch {
    return $Path.TrimEnd('\\')
  }
}

function Set-TerraformMachinePath {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [string]$BinDirectory,
    [switch]$SkipShouldProcessCheck
  )

  $normalized = Get-NormalizedPath -Path $BinDirectory
  $machineUpdated = $false
  $processUpdated = $false

  if (-not $SkipShouldProcessCheck) {
    if (-not $PSCmdlet.ShouldProcess("PATH variables", "Ensure Terraform directory '$normalized' is registered globally")) {
      return @{ MachineUpdated = $false; ProcessUpdated = $false }
    }
  }

  $delimiter = ';'
  $machinePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
  $machineEntries = @()
  if ($machinePath) {
    $machineEntries = $machinePath -split $delimiter
  }

  if (-not ($machineEntries | Where-Object { $_.TrimEnd('\\') -ieq $normalized })) {
    $machineEntries = $machineEntries + $normalized
    $newMachinePath = ($machineEntries | Where-Object { $_ }) -join $delimiter
    [Environment]::SetEnvironmentVariable('Path', $newMachinePath, [EnvironmentVariableTarget]::Machine)
    $machineUpdated = $true
  }

  $processEntries = @()
  if ($env:Path) {
    $processEntries = $env:Path -split $delimiter
  }

  if (-not ($processEntries | Where-Object { $_.TrimEnd('\\') -ieq $normalized })) {
    $env:Path = ($processEntries + $normalized | Where-Object { $_ }) -join $delimiter
    $processUpdated = $true
  }

  return @{ MachineUpdated = $machineUpdated; ProcessUpdated = $processUpdated }
}

function Send-EnvironmentChangeNotification {
  try {
    $typeName = 'Win32.NativeMethods'
    if (-not ($typeName -as [Type])) {
      $signature = @"
using System;
using System.Runtime.InteropServices;

public static class NativeMethods
{
  [DllImport(""user32.dll"", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd,
    int Msg,
    IntPtr wParam,
    string lParam,
    int fuFlags,
    int uTimeout,
    out IntPtr lpdwResult);
}
"@
      Add-Type -TypeDefinition $signature -ErrorAction Stop
    }

    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1A
    $SMTO_ABORTIFHUNG = 0x2
    [IntPtr]$result = [IntPtr]::Zero

    [Win32.NativeMethods]::SendMessageTimeout(
      $HWND_BROADCAST,
      $WM_SETTINGCHANGE,
      [IntPtr]::Zero,
      'Environment',
      $SMTO_ABORTIFHUNG,
      5000,
      [ref]$result
    ) | Out-Null
  } catch {
    Write-Warning "Failed to broadcast PATH change to other processes: $($_.Exception.Message)"
  }
}

function Install-AzureCLI {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param()

  if (-not $PSCmdlet.ShouldProcess("Azure CLI", "Install or upgrade")) {
    return $false
  }

  $downloadUri = 'https://aka.ms/installazurecliwindows'
  $workingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("azurecli-" + [System.Guid]::NewGuid().ToString())
  $msiPath = Join-Path $workingRoot 'azure-cli.msi'

  try {
    New-Item -ItemType Directory -Path $workingRoot -Force | Out-Null

    Write-Host "Downloading Azure CLI installer..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $downloadUri -OutFile $msiPath -UseBasicParsing -ErrorAction Stop

    Write-Host "Installing Azure CLI..." -ForegroundColor Cyan
  $msiInstallArgs = @('/i', "`"$msiPath`"", '/qn', '/norestart')
  $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiInstallArgs -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
      throw "Azure CLI installer returned exit code $($process.ExitCode)."
    }

    return $true
  } finally {
    if (Test-Path -LiteralPath $workingRoot) {
      Remove-Item -LiteralPath $workingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-AzureCLIVersion {
  try {
    $azCommand = Get-Command az -ErrorAction Stop
    $output = & $azCommand.Source --version 2>$null
    $firstLine = $null
    if ($LASTEXITCODE -eq 0 -and $output) {
      $firstLine = ($output -split "`n")[0].Trim()
    }

    return [PSCustomObject]@{
      Path        = $azCommand.Source
      VersionText = $firstLine
      RawOutput   = $output
    }
  } catch {
    return $null
  }
}

function Update-AzureCLIPathForSession {
  $candidateDirs = @(
    'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin',
    'C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin'
  )

  foreach ($dir in $candidateDirs) {
    if (Test-Path -LiteralPath $dir) {
      $normalized = Get-NormalizedPath -Path $dir
      $currentEntries = $env:Path -split ';'
      if (-not ($currentEntries | Where-Object { $_.TrimEnd('\\') -ieq $normalized })) {
        $env:Path = ($currentEntries + $normalized | Where-Object { $_ }) -join ';'
      }
    }
  }
}

try {
  $targetVersion = Resolve-TerraformVersion -RequestedVersion $Version
  Write-Host "Target Terraform version: $targetVersion" -ForegroundColor Gray

  $currentVersion = Get-InstalledTerraformVersion -ExecutablePath $terraformExecutablePath
  if ($currentVersion) {
    Write-Host "Currently installed Terraform version: $currentVersion" -ForegroundColor Gray
  } else {
    Write-Host "Terraform is not currently installed at $terraformExecutablePath." -ForegroundColor Gray
  }

  $terraformInstalled = $false
  $pathResult = $null

  if ($currentVersion -and ($currentVersion -eq $targetVersion) -and -not $Force) {
    Write-Host "Terraform $currentVersion already present. Ensuring PATH configuration..." -ForegroundColor Green
    $pathResult = Set-TerraformMachinePath -BinDirectory $terraformInstallDirectory
  } else {
    $terraformInstalled = Install-Terraform -ResolvedVersion $targetVersion -InstallDirectory $terraformInstallDirectory -ExecutablePath $terraformExecutablePath
    if ($terraformInstalled) {
      $pathResult = Set-TerraformMachinePath -BinDirectory $terraformInstallDirectory -SkipShouldProcessCheck
      Write-Host "Terraform $targetVersion installed at $terraformExecutablePath" -ForegroundColor Green
    }
  }

  if ($pathResult -and $pathResult.MachineUpdated) {
    Send-EnvironmentChangeNotification
  }

  if (-not $whatIfActive) {
    $machinePathEntries = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine) -split ';'
    $machineHasTerraform = $machinePathEntries | Where-Object { $_.TrimEnd('\\') -ieq $terraformInstallDirectory.TrimEnd('\\') }
    if ($machineHasTerraform) {
      Write-Host "Machine PATH confirmed to include: $terraformInstallDirectory" -ForegroundColor Green
    } else {
      Write-Warning "Terraform directory not found on machine PATH registry entry. Re-running with elevation may be required."
    }
  }

  if (Test-Path -LiteralPath $terraformExecutablePath) {
    try {
      $versionOutput = & $terraformExecutablePath -version 2>$null
      if (-not $versionOutput) {
        throw "Terraform did not return version information."
      }
      Write-Host "Terraform is ready:" -ForegroundColor Green
      Write-Host $versionOutput

      try {
        $terraformCommand = Get-Command terraform -ErrorAction Stop
        Write-Host "Terraform command resolves to: $($terraformCommand.Source)" -ForegroundColor Gray
      } catch {
        Write-Warning "Terraform isn't on the current session PATH yet. Open a new PowerShell window (or run 'refreshenv' if available) to pick up machine PATH changes."
      }
    } catch {
      throw "Terraform installation verification failed: $($_.Exception.Message)"
    }
  } elseif ($whatIfActive) {
    Write-Host "Terraform would be installed to '$terraformExecutablePath' when running without -WhatIf." -ForegroundColor Yellow
  } else {
    throw "Terraform executable not found at '$terraformExecutablePath'."
  }

  if ($InstallAzureCLI) {
    $existingAzureCli = Get-AzureCLIVersion
    if ($existingAzureCli) {
      Update-AzureCLIPathForSession
      $versionSummary = if ($existingAzureCli.VersionText) { $existingAzureCli.VersionText } else { 'Version information unavailable' }
      Write-Host "Azure CLI already installed: $versionSummary." -ForegroundColor Green
      Write-Host "Location: $($existingAzureCli.Path)" -ForegroundColor Gray
    } else {
      $azureCliInstalled = Install-AzureCLI
      if ($azureCliInstalled) {
        Update-AzureCLIPathForSession
        if (-not $whatIfActive) {
          try {
            $azVersion = & az --version 2>$null
            Write-Host "Azure CLI ready:" -ForegroundColor Green
            Write-Host $azVersion
          } catch {
            Write-Warning "Azure CLI installed but verification failed. Open a new shell and run 'az --version'. Details: $($_.Exception.Message)"
          }
        } else {
          Write-Host "Azure CLI installation was skipped due to -WhatIf." -ForegroundColor Yellow
        }
      } elseif ($whatIfActive) {
        Write-Host "Azure CLI would be installed when running without -WhatIf." -ForegroundColor Yellow
      }
    }
  }

  if (-not $whatIfActive) {
    Write-Host "`nNext steps:" -ForegroundColor Yellow
    Write-Host "  terraform -help"
    Write-Host "  terraform init   # inside a folder with your Terraform configuration"
    Write-Host "  terraform plan"
    Write-Host "  terraform apply"
    Write-Host "`nIf you launched this script from another PowerShell process, close and reopen that window so the updated machine PATH is loaded." -ForegroundColor Yellow
  } else {
    Write-Host "`nWhatIf: No changes were made. Re-run without -WhatIf to perform the installation." -ForegroundColor Yellow
  }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}