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
    foreach ($candidate in @('D:\MiniMaxH3\ComfyUI','C:\MiniMaxH3\ComfyUI','E:\MiniMaxH3\ComfyUI','D:\ComfyUI','C:\ComfyUI','E:\ComfyUI')) {
        if (Test-ComfyRoot $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the ComfyUI root folder to roll back TE-Speed.'
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw 'Folder selection was cancelled.' }
    $selected = [IO.Path]::GetFullPath($dialog.SelectedPath)
    if (Test-ComfyRoot $selected) { return $selected }
    $nested = Join-Path $selected 'ComfyUI'
    if (Test-ComfyRoot $nested) { return [IO.Path]::GetFullPath($nested) }
    throw "The selected path is not a recognized ComfyUI root: $selected"
}

function Find-Python([string]$Root) {
    $parent = Split-Path $Root -Parent
    foreach ($candidate in @(
        (Join-Path $parent 'runtime\venv\Scripts\python.exe'),
        (Join-Path $Root 'runtime\venv\Scripts\python.exe'),
        (Join-Path $parent 'python_embeded\python.exe'),
        (Join-Path $parent 'python_embedded\python.exe'),
        (Join-Path $Root 'python_embeded\python.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'Python was not found; safe rollback cannot continue.'
}

try {
    $comfy = Select-ComfyRoot $ComfyUI
    $python = Find-Python $comfy
    $plugin = Join-Path $comfy 'custom_nodes\TE-Speed-MiniMaxH3-OSS'
    $patchScript = Join-Path $plugin 'patch_model.py'
    $workflowScript = Join-Path $plugin 'tespeed_workflow_patch.py'
    if (-not (Test-Path -LiteralPath $patchScript)) { $patchScript = Join-Path $repoRoot 'patch_model.py' }
    if (-not (Test-Path -LiteralPath $workflowScript)) { $workflowScript = Join-Path $repoRoot 'tespeed_workflow_patch.py' }
    if (-not (Test-Path -LiteralPath $patchScript)) { throw 'patch_model.py was not found.' }
    if (-not (Test-Path -LiteralPath $workflowScript)) { throw 'tespeed_workflow_patch.py was not found.' }

    Write-Host "ComfyUI: $comfy"
    Write-Host '[1/3] Safely restoring the MiniMax H3 core...'
    & $python $patchScript --comfy-ui $comfy --revert
    if ($LASTEXITCODE -ne 0) { throw "Core rollback failed with exit code $LASTEXITCODE." }

    Write-Host '[2/3] Restoring workflows modified by the one-click installer...'
    $workflowDir = Join-Path $comfy 'user\default\workflows'
    if (Test-Path -LiteralPath $workflowDir -PathType Container) {
        $workflowFiles = @(Get-ChildItem -LiteralPath $workflowDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        foreach ($wf in $workflowFiles) {
            $bak = $wf.FullName + '.tespeed_wf.bak'
            if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) { continue }
            $currentText = Get-Content -LiteralPath $wf.FullName -Raw -ErrorAction SilentlyContinue
            if ($currentText -notmatch 'TESpeedMiniMaxH3') {
                Write-Host "[SAFE] $($wf.Name) no longer contains TE-Speed; an old backup will not overwrite it."
                continue
            }
            $safety = $wf.FullName + '.tespeed_wf.before_revert.bak'
            Copy-Item -LiteralPath $wf.FullName -Destination $safety -Force
            & $python $workflowScript --revert $wf.FullName
            if ($LASTEXITCODE -ne 0) { Write-Warning "Workflow rollback failed: $($wf.Name)" }
        }
    }

    Write-Host '[3/3] Removing the TE-Speed custom node...'
    if (Test-Path -LiteralPath $plugin -PathType Container) {
        Remove-Item -LiteralPath $plugin -Recurse -Force
    }

    Write-Host ''
    Write-Host 'TE-Speed rollback completed. Fully restart ComfyUI.' -ForegroundColor Green
    Write-Host 'Original backups and before-revert workflow safety copies are retained.'
    [Windows.Forms.MessageBox]::Show(
        "TE-Speed rollback completed.`n`nFully close and restart ComfyUI.`nBackups are retained for recovery.",
        'TE-Speed rollback completed', 'OK', 'Information') | Out-Null
    exit 0
} catch {
    Write-Host ("Rollback failed: " + $_.Exception.Message) -ForegroundColor Red
    [Windows.Forms.MessageBox]::Show(
        "TE-Speed rollback did not complete.`n`n$($_.Exception.Message)",
        'TE-Speed rollback failed', 'OK', 'Error') | Out-Null
    exit 1
}
