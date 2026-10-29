# Installs SimpoConverter for the current user on Windows 10 or 11.
# Administrator rights and Python are not required.
#
# Install or reinstall from PowerShell:
#   irm https://raw.githubusercontent.com/nambobi/SimpoConverter/main/install.ps1 | iex
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Installer that writes coloured status messages to the console.')]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 }  # TLS 1.2
catch { Write-Verbose 'TLS 1.2 could not be enabled.' }

$RepoRaw    = 'https://raw.githubusercontent.com/nambobi/SimpoConverter/main'
$InstallDir = Join-Path $env:LOCALAPPDATA 'SimpoConverter'
$LibDir     = Join-Path $InstallDir 'lib'

Write-Host ''
Write-Host 'Installing SimpoConverter...' -ForegroundColor Cyan
New-Item -ItemType Directory -Path $LibDir -Force | Out-Null

# 1. Copy the script from this folder if present, otherwise download it.
$target = Join-Path $LibDir 'simpoconv.ps1'
$localCopy = $null
if ($PSScriptRoot) { $localCopy = Join-Path $PSScriptRoot 'simpoconv.ps1' }
if ($localCopy -and (Test-Path -LiteralPath $localCopy)) {
    Copy-Item -LiteralPath $localCopy -Destination $target -Force
} else {
    Invoke-WebRequest -Uri "$RepoRaw/simpoconv.ps1" -UseBasicParsing -OutFile $target
}
try { Unblock-File -LiteralPath $target }
catch { Write-Verbose 'Unblock-File is not available.' }

# 2. Create simpoconv.cmd. It runs the script with -ExecutionPolicy Bypass,
#    so the command works in both cmd and PowerShell.
$cmd = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0lib\simpoconv.ps1`" %*`r`nexit /b %errorlevel%`r`n"
[IO.File]::WriteAllText((Join-Path $InstallDir 'simpoconv.cmd'), $cmd, [Text.Encoding]::ASCII)

# 3. Add the install folder to the user PATH. The value is kept as
#    REG_EXPAND_SZ so that entries such as %USERPROFILE% still expand.
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
$userPath = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
if (-not ($parts | Where-Object { $_.TrimEnd('\') -eq $InstallDir.TrimEnd('\') })) {
    $key.SetValue('Path', ((@($parts) + $InstallDir) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    # Setting a user variable broadcasts WM_SETTINGCHANGE, so new terminals see the new PATH.
    [Environment]::SetEnvironmentVariable('SIMPOCONV_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('SIMPOCONV_REFRESH', $null, 'User')
}
$key.Close()
# Update PATH for the current session.
if (($env:Path -split ';') -notcontains $InstallDir) { $env:Path = "$env:Path;$InstallDir" }

$version = ''
if ((Get-Content -LiteralPath $target -Raw) -match "\`$AppVersion\s*=\s*'([^']+)'") { $version = $matches[1] }
Write-Host "SimpoConverter $version installed in $InstallDir" -ForegroundColor Green
Write-Host ''
Write-Host 'Usage:' -ForegroundColor Cyan
Write-Host '   simpoconv                   guided mode'
Write-Host '   simpoconv "file.pdf"        convert all pages to PNG at 150 dpi'
Write-Host '   simpoconv help              list all options'
Write-Host ''
