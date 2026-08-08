#requires -version 5.1
param([string]$ComfyUI)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-ComfyRoot([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path 'main.py') -PathType Leaf) -and
           (Test-Path -LiteralPath (Join-Path $Path 'comfy\ldm\minimax\model.py') -PathType Leaf)
}

function Select-ComfyRoot {
    param([string]$Requested)
    if ($Requested) {
        $full = [IO.Path]::GetFullPath($Requested)
        if (Test-ComfyRoot $full) { return $full }
        $nested = Join-Path $full 'ComfyUI'
        if (Test-ComfyRoot $nested) { return [IO.Path]::GetFullPath($nested) }
        throw "The selected path is not a recognized ComfyUI root: $Requested"
    }

    $candidates = @(
        (Join-Path $repoRoot 'ComfyUI'),
        (Join-Path (Split-Path $repoRoot -Parent) 'ComfyUI'),
        'D:\MiniMaxH3\ComfyUI',
        'C:\MiniMaxH3\ComfyUI',
        'E:\MiniMaxH3\ComfyUI',
        'D:\ComfyUI',
        'C:\ComfyUI',
        'E:\ComfyUI'
    ) | Select-Object -Unique
    foreach ($candidate in $candidates) {
        if (Test-ComfyRoot $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }

    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the ComfyUI root folder containing main.py, comfy, and custom_nodes.'
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
        throw 'Folder selection was cancelled.'
    }
    $selected = [IO.Path]::GetFullPath($dialog.SelectedPath)
    if (Test-ComfyRoot $selected) { return $selected }
    $nested = Join-Path $selected 'ComfyUI'
    if (Test-ComfyRoot $nested) { return [IO.Path]::GetFullPath($nested) }
    throw "The selected path is not a recognized ComfyUI root: $selected"
}

function Find-Python([string]$Root) {
    $parent = Split-Path $Root -Parent
    $candidates = @(
        (Join-Path $parent 'runtime\venv\Scripts\python.exe'),
        (Join-Path $Root 'runtime\venv\Scripts\python.exe'),
        (Join-Path $parent 'python_embeded\python.exe'),
        (Join-Path $parent 'python_embedded\python.exe'),
        (Join-Path $Root 'python_embeded\python.exe')
    ) | Select-Object -Unique
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'Python was not found. MiniMaxH3 Installer normally provides runtime\venv\Scripts\python.exe.'
}

function Copy-IfDifferent([string]$Source, [string]$Destination) {
    $srcFull = [IO.Path]::GetFullPath($Source)
    $dstFull = [IO.Path]::GetFullPath($Destination)
    if ($srcFull.Equals($dstFull, [StringComparison]::OrdinalIgnoreCase)) { return }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

try {
    $comfy = Select-ComfyRoot $ComfyUI
    $python = Find-Python $comfy
    $plugin = Join-Path $comfy 'custom_nodes\TE-Speed-MiniMaxH3-OSS'
    New-Item -ItemType Directory -Force -Path $plugin | Out-Null

    Write-Host "[1/5] ComfyUI: $comfy"
    Write-Host "[2/5] Python : $python"
    Write-Host '[3/5] Installing TE-Speed custom node...'

    $payload = @('__init__.py','nodes.py','patch_model.py','tespeed_workflow_patch.py','README.md')
    foreach ($name in $payload) {
        $source = Join-Path $repoRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Installer payload is missing: $name" }
        Copy-IfDifferent $source (Join-Path $plugin $name)
    }
    foreach ($txt in @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
        Copy-IfDifferent $txt.FullName (Join-Path $plugin $txt.Name)
    }

    Write-Host '[4/5] Installing reversible MiniMax H3 core hook...'
    & $python (Join-Path $plugin 'patch_model.py') --comfy-ui $comfy
    if ($LASTEXITCODE -ne 0) {
        throw "Core patch failed with exit code $LASTEXITCODE. An unrecognized ComfyUI version is not modified forcibly."
    }

    $workflowDir = Join-Path $comfy 'user\default\workflows'
    Write-Host '[5/5] Adding TE-Speed to recognized MiniMax H3 workflows...'
    if (Test-Path -LiteralPath $workflowDir -PathType Container) {
        & $python (Join-Path $plugin 'tespeed_workflow_patch.py') --add $workflowDir
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Some workflows did not match the expected wiring and were safely skipped.'
        }
    } else {
        Write-Warning "Workflow directory was not found: $workflowDir. Add the TE-Speed node manually if needed."
    }

    $state = [ordered]@{
        installed_at = (Get-Date).ToString('o')
        comfy_ui = $comfy
        python = $python
        plugin = $plugin
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $plugin 'te-speed-install.json') -Encoding UTF8

    Write-Host ''
    Write-Host 'TE-Speed installation completed. Fully restart ComfyUI before use.' -ForegroundColor Green
    Write-Host 'Defaults: threshold=0.12, window=0.10..0.90, mcs=2, cache_depth=0.75.'
    Write-Host 'Use the one-click rollback BAT if compatibility or quality problems occur.'
    [Windows.Forms.MessageBox]::Show(
        "TE-Speed installation completed.`n`nFully close and restart ComfyUI before use.`n`nUse the rollback BAT if you encounter problems.",
        'TE-Speed MiniMax H3', 'OK', 'Information') | Out-Null
    exit 0
} catch {
    Write-Host ''
    Write-Host ("Installation failed: " + $_.Exception.Message) -ForegroundColor Red
    [Windows.Forms.MessageBox]::Show(
        "TE-Speed installation did not complete.`n`n$($_.Exception.Message)`n`nSee the console for details.",
        'TE-Speed installation failed', 'OK', 'Error') | Out-Null
    exit 1
}
