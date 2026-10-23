param(
    [string]$GamePath = ""
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Starmancer Restore Vanilla Tool" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

$resolvedGamePath = ""
$candidates = @()

if (-not [string]::IsNullOrWhiteSpace($GamePath)) { $candidates += $GamePath }
$candidates += (Join-Path $scriptDir '..')
$candidates += $scriptDir
$candidates += 'D:\SteamLibrary\steamapps\common\Starmancer'
$candidates += 'C:\Program Files (x86)\Steam\steamapps\common\Starmancer'
$candidates += 'C:\SteamLibrary\steamapps\common\Starmancer'
$candidates += 'E:\SteamLibrary\steamapps\common\Starmancer'
$candidates += 'F:\SteamLibrary\steamapps\common\Starmancer'

foreach ($cand in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($cand) -and (Test-Path $cand)) {
        $testTarget = Join-Path $cand 'Starmancer_Data\Managed\StarmancerMod.dll.orig'
        if (Test-Path $testTarget) {
            $resolvedGamePath = (Resolve-Path $cand).Path
            break
        }
    }
}

while ([string]::IsNullOrWhiteSpace($resolvedGamePath)) {
    Write-Host "Could not automatically detect Starmancer folder with a .orig backup." -ForegroundColor Yellow
    $userInput = Read-Host "Please enter your Starmancer game folder"
    if ([string]::IsNullOrWhiteSpace($userInput)) {
        Write-Error "No path provided. Aborting restore."
        exit 1
    }
    $resolvedGamePath = $userInput.Trim('"', "'")
}

$managedDir = Join-Path $resolvedGamePath 'Starmancer_Data\Managed'
$targetDll = Join-Path $managedDir 'StarmancerMod.dll'
$backupDll = Join-Path $managedDir 'StarmancerMod.dll.orig'

if (-not (Test-Path $backupDll)) {
    Write-Error "Backup file not found at '$backupDll'."
    exit 1
}

Copy-Item $backupDll $targetDll -Force
Write-Host "SUCCESS! Vanilla StarmancerMod.dll has been restored." -ForegroundColor Green
Write-Host ""