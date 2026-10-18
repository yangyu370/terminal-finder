#requires -Version 7.2
param([switch]$PreviewOnly)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run this script in native Windows PowerShell 7.' }
Push-Location $PSScriptRoot
$oldCGO = $env:CGO_ENABLED
$oldTarget = $env:CARGO_TARGET_DIR
try {
    $env:CGO_ENABLED = '0'
    New-Item -ItemType Directory -Force .\dist, .\.cache\natives | Out-Null
    go build -trimpath -ldflags '-H=windowsgui -s -w' -o .\dist\terminal-finder-drawn.exe ./cmd/terminal-finder-drawn
    if ($LASTEXITCODE -ne 0) { throw 'Go client build failed' }
    if (-not $PreviewOnly) {
        $env:CARGO_TARGET_DIR = Join-Path $PSScriptRoot '.cache\rust-target'
        cargo build --locked --manifest-path ..\..\core\Cargo.toml --features server --bin core
        if ($LASTEXITCODE -ne 0) { throw 'Rust core build failed' }
        Copy-Item .\.cache\rust-target\debug\core.exe .\dist\core.exe -Force
        $module = go list -m -f '{{.Dir}}' github.com/egoist/mygo
        if ($LASTEXITCODE -ne 0) { throw 'Cannot locate MyGo module' }
        $manifest = Get-Content (Join-Path $module 'plugins\terminal\mygo-plugin.json') -Raw | ConvertFrom-Json
        $arch = go env GOARCH
        $entry = $manifest.libraries[0].files."windows-$arch"
        if (-not $entry) { throw "No matching Ghostty VT library for windows-$arch" }
        $dll = Join-Path $PSScriptRoot 'dist\ghostty-vt.dll'
        if (-not (Test-Path $dll) -or (Get-FileHash $dll -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) {
            Invoke-WebRequest -Uri $entry.url -OutFile $dll
        }
        if ((Get-FileHash $dll -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) { throw 'Ghostty VT SHA256 mismatch' }
    }
    Write-Host 'Built dist\terminal-finder-drawn.exe (full mode also includes core.exe and ghostty-vt.dll)'
} finally {
    $env:CGO_ENABLED = $oldCGO
    $env:CARGO_TARGET_DIR = $oldTarget
    Pop-Location
}
