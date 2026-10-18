#requires -Version 7.2
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\build-windows.ps1"
Push-Location $PSScriptRoot
try {
    $env:CGO_ENABLED = '0'
    $env:TF_CORE_BINARY = (Resolve-Path .\dist\core.exe).Path
    $env:MYGO_GHOSTTY_VT = (Resolve-Path .\dist\ghostty-vt.dll).Path
    $env:TF_PREVIEW = Join-Path $PSScriptRoot '.cache\windows-terminal.png'
    go vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'go vet failed' }
    go test -v -p 1 -count=1 -timeout 5m ./... 2>&1 | Tee-Object .\.cache\windows-tests.log
    if ($LASTEXITCODE -ne 0) { throw 'Windows tests failed' }
} finally { Pop-Location }
