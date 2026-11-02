Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serverPath = Join-Path $PSScriptRoot '..\src\Astra.Server'
$desktopPath = Join-Path $PSScriptRoot '..\src\Astra.Desktop'
$publishPath = Join-Path $PSScriptRoot '..\publish'

$serverProject = Join-Path $serverPath 'Astra.Server.csproj'
$desktopProject = Join-Path $desktopPath 'Astra.Desktop.csproj'

$serverPublishPath = Join-Path $serverPath 'bin\publish\win-x64-aot'
$desktopPublishPath = Join-Path $desktopPath 'bin\publish\win-x64-aot'

$framework = 'net11.0'
$configuration = 'Release'
$publishProfile = 'win-x64-aot'

function Assert-PathExists {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [Parameter(Mandatory)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        throw "$Description not found: $LiteralPath"
    }
}

function Remove-GeneratedDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    if (Test-Path -LiteralPath $LiteralPath) {
        Remove-Item -LiteralPath $LiteralPath -Recurse -Force
    }
}

function Copy-PublishFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$Destination,
        [string]$RenameFrom,
        [string]$RenameTo
    )

    Assert-PathExists -LiteralPath $Source -Description 'Publish output'
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force)
    if ($files.Count -eq 0) {
        throw "Publish output is empty: $sourceRoot"
    }

    foreach ($file in $files) {
        if ($file.Extension -ieq '.pdb') {
            continue
        }

        $relativePath = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
        if ($RenameFrom -and $relativePath -ieq $RenameFrom) {
            $relativePath = $RenameTo
        }

        $destinationFile = Join-Path $Destination $relativePath
        $destinationDirectory = Split-Path -Parent $destinationFile
        if ($destinationDirectory) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }

        Copy-Item -LiteralPath $file.FullName -Destination $destinationFile -Force
    }
}

Assert-PathExists -LiteralPath $serverProject -Description 'Server project'
Assert-PathExists -LiteralPath $desktopProject -Description 'Desktop project'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet was not found on PATH."
}

Remove-GeneratedDirectory -LiteralPath $serverPublishPath
Remove-GeneratedDirectory -LiteralPath $desktopPublishPath

Write-Host 'Publishing server...'
$serverJob = Start-ThreadJob -Name 'Publish server' -ArgumentList $serverProject, $framework, $configuration, $publishProfile -ScriptBlock {
    param($ProjectPath, $TargetFramework, $BuildConfiguration, $BuildProfile)

    $ErrorActionPreference = 'Stop'
    & dotnet publish $ProjectPath --framework $TargetFramework --configuration $BuildConfiguration "-p:PublishProfile=$BuildProfile"
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE for $ProjectPath"
    }
}

Write-Host 'Publishing desktop...'
$desktopJob = Start-ThreadJob -Name 'Publish desktop' -ArgumentList $desktopProject, $framework, $configuration, $publishProfile -ScriptBlock {
    param($ProjectPath, $TargetFramework, $BuildConfiguration, $BuildProfile)
    
    $ErrorActionPreference = 'Stop'
    & dotnet publish $ProjectPath --framework $TargetFramework --configuration $BuildConfiguration "-p:PublishProfile=$BuildProfile"
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE for $ProjectPath"
    }
}

$publishJobs = @($serverJob, $desktopJob)
try {
    Wait-Job -Job $publishJobs | Out-Null

    $failedJobs = @()
    foreach ($job in $publishJobs) {
        Receive-Job -Job $job -ErrorAction Continue 2>&1 | ForEach-Object { Write-Host $_ }
        if ($job.State -ne 'Completed') {
            $failedJobs += $job.Name
        }
    }

    if ($failedJobs.Count -gt 0) {
        throw "Publish failed: $($failedJobs -join ', ')"
    }

    Remove-GeneratedDirectory -LiteralPath $publishPath
    New-Item -ItemType Directory -Path $publishPath -Force | Out-Null

    $serverDestination = Join-Path $publishPath 'resources\server'
    Copy-PublishFiles -Source $serverPublishPath -Destination $serverDestination
    Copy-PublishFiles -Source $desktopPublishPath -Destination $publishPath -RenameFrom 'astra-desktop.exe' -RenameTo 'Astra.exe'

    Write-Host "Publish completed: $publishPath"
}
finally {
    foreach ($job in $publishJobs) {
        if ($job.State -in @('Running', 'NotStarted')) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}
