# Session-local bootstrap. Never writes profiles or executes control data as code.
trap { [Console]::Error.WriteLine('Terminal Finder requires PowerShell 7 and PSReadLine 2.2 or newer. ' + $_.Exception.Message); exit 78 }
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.2') { throw 'PowerShell 7.2+ is required' }
Import-Module PSReadLine -ErrorAction Stop
if ((Get-Module PSReadLine).Version -lt [version]'2.2') { throw 'PSReadLine 2.2+ is required for safe idle directory synchronization' }
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$global:OutputEncoding = [Text.UTF8Encoding]::new($false)
$global:TfControlDirectory = $env:TF_CONTROL_DIRECTORY
$global:TfControlSequence = [long]0

function global:Send-TfDirectory {
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return }
    $path = $location.ProviderPath.Replace('\', '/')
    if ($path.StartsWith('//?/UNC/', [StringComparison]::OrdinalIgnoreCase)) { $path = '//' + $path.Substring(8) }
    elseif ($path.StartsWith('//?/')) { $path = $path.Substring(4) }
    if (-not $path.StartsWith('/')) { $path = '/' + $path }
    $escaped = ($path.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    [Console]::Write("$([char]27)]7;file://localhost$escaped$([char]27)\")
}
function global:Invoke-TfDirectoryRequest {
    param([switch]$AtPrompt)
    if (-not $AtPrompt) {
        $line = ''; $cursor = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ($line.Length -gt 0) { return $false }
    }
    $file = Get-ChildItem -LiteralPath (Join-Path $global:TfControlDirectory 'requests') -Filter '*.json' -File |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $file) { return $false }
    try { $request = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -ErrorAction Stop }
    catch { return $false }
    if ([long]$request.sequence -le $global:TfControlSequence) { return $false }
    $global:TfControlSequence = [long]$request.sequence
    $success = $false
    try {
        if ([string]::IsNullOrWhiteSpace($request.target) -or [string]$request.target -match '[\x00-\x1f\x7f]') { throw 'Invalid directory' }
        # This function belongs to the main session, not the event action module.
        $target = [string]$request.target
        if ($target.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $target = '\\' + $target.Substring(8) }
        elseif ($target.StartsWith('\\?\')) { $target = $target.Substring(4) }
        Set-Location -LiteralPath $target -ErrorAction Stop
        $success = (Get-Location).Provider.Name -eq 'FileSystem'
    } catch { $success = $false }
    $completion = @{ sequence = $global:TfControlSequence; target = [string]$request.target; success = $success } | ConvertTo-Json -Compress
    $temp = Join-Path $global:TfControlDirectory ('completion.' + [guid]::NewGuid() + '.tmp')
    [IO.File]::WriteAllText($temp, $completion, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, (Join-Path $global:TfControlDirectory 'completion.json'), $true)
    Get-ChildItem -LiteralPath (Join-Path $global:TfControlDirectory 'requests') -Filter '*.json' -File |
        Where-Object { $_.Name -le $file.Name } | Remove-Item -Force -ErrorAction SilentlyContinue
    # Acknowledgment must not depend on InvokePrompt (which may skip redraw).
    if ($success) { Send-TfDirectory }
    return $success
}
function global:prompt {
    $null = Invoke-TfDirectoryRequest -AtPrompt
    Send-TfDirectory
    [Console]::Write("$([char]27)]133;A$([char]27)\")
    return 'PS ' + (Get-Location).Path + '> '
}
$null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -SupportEvent -Action {
    if (Invoke-TfDirectoryRequest) {
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
    }
}
$ErrorActionPreference = 'Continue'
