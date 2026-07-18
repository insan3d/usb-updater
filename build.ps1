param(
    [Parameter(Position = 0)]
    [ValidateSet("lint", "binaries", "release", "clean")]
    [string]$Target = "release"
)

$ErrorActionPreference = "Stop"

$workspace = $PSScriptRoot
$au3Check = "C:\Program Files (x86)\AutoIt3\Au3Check.exe"
$aut2Exe = "C:\Program Files (x86)\AutoIt3\Aut2Exe\Aut2exe.exe"
$innoCompiler = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"

function Invoke-Tool {
    param(
        [string]$Path,
        [string[]]$ToolArgs
    )

    & $Path @ToolArgs
    $exitCode = $global:LASTEXITCODE
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        throw "Команда завершилась с кодом ${LASTEXITCODE}: $Path"
    }
}

function Invoke-Lint {
    Invoke-Tool $au3Check @("updater_gui.au3")
    Invoke-Tool $au3Check @("updater_worker.au3")
}

function Invoke-BinaryBuild {
    Invoke-Tool $aut2Exe @("/in", "updater_gui.au3", "/out", "usb-updater.exe", "/x86", "/gui")
    Invoke-Tool $aut2Exe @("/in", "updater_worker.au3", "/out", "usb-updater-worker.exe", "/x86", "/console")
}

function Invoke-ReleaseBuild {
    Invoke-Lint
    Invoke-BinaryBuild
    Invoke-Tool $innoCompiler @("installer.iss")
}

function Remove-BuildArtifacts {
    $files = @(
        (Join-Path $workspace "usb-updater.exe"),
        (Join-Path $workspace "usb-updater-worker.exe")
    )

    foreach ($file in $files) {
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file -Force
        }
    }

    $dist = Join-Path $workspace "dist"
    if (Test-Path -LiteralPath $dist) {
        $resolvedDist = (Resolve-Path -LiteralPath $dist).Path
        if (-not $resolvedDist.StartsWith($workspace, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Небезопасный путь для очистки: $resolvedDist"
        }

        Remove-Item -LiteralPath $resolvedDist -Recurse -Force
    }
}

Push-Location $workspace
try {
    switch ($Target) {
        "lint" { Invoke-Lint }
        "binaries" { Invoke-BinaryBuild }
        "release" { Invoke-ReleaseBuild }
        "clean" { Remove-BuildArtifacts }
    }
}
finally {
    Pop-Location
}
