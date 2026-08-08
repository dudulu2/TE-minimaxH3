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
        if (Test-ComfyRoot (Join-Path $full 'ComfyUI')) { return [IO.Path]::GetFullPath((Join-Path $full 'ComfyUI')) }
        throw "指定目录不是可识别的 ComfyUI：$Requested"
    }
    foreach ($candidate in @('D:\MiniMaxH3\ComfyUI','C:\MiniMaxH3\ComfyUI','E:\MiniMaxH3\ComfyUI','D:\ComfyUI','C:\ComfyUI','E:\ComfyUI')) {
        if (Test-ComfyRoot $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = '请选择要回退 TE-Speed 的 ComfyUI 根目录'
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw '用户取消了目录选择。' }
    $selected = [IO.Path]::GetFullPath($dialog.SelectedPath)
    if (Test-ComfyRoot $selected) { return $selected }
    if (Test-ComfyRoot (Join-Path $selected 'ComfyUI')) { return [IO.Path]::GetFullPath((Join-Path $selected 'ComfyUI')) }
    throw "选择的目录不是可识别的 ComfyUI：$selected"
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
    throw '找不到 Python，无法执行安全回退脚本。'
}

try {
    $comfy = Select-ComfyRoot $ComfyUI
    $python = Find-Python $comfy
    $plugin = Join-Path $comfy 'custom_nodes\TE-Speed-MiniMaxH3-OSS'
    $patchScript = Join-Path $plugin 'patch_model.py'
    $workflowScript = Join-Path $plugin 'tespeed_workflow_patch.py'
    if (-not (Test-Path -LiteralPath $patchScript)) { $patchScript = Join-Path $repoRoot 'patch_model.py' }
    if (-not (Test-Path -LiteralPath $workflowScript)) { $workflowScript = Join-Path $repoRoot 'tespeed_workflow_patch.py' }
    if (-not (Test-Path -LiteralPath $patchScript)) { throw '找不到 patch_model.py。' }
    if (-not (Test-Path -LiteralPath $workflowScript)) { throw '找不到 tespeed_workflow_patch.py。' }

    Write-Host "ComfyUI: $comfy"
    Write-Host '[1/3] 安全恢复 MiniMax H3 核心...'
    & $python $patchScript --comfy-ui $comfy --revert
    if ($LASTEXITCODE -ne 0) { throw "核心回退失败，退出码 $LASTEXITCODE。" }

    Write-Host '[2/3] 恢复被 TE 自动修改的工作流...'
    $workflowDir = Join-Path $comfy 'user\default\workflows'
    if (Test-Path -LiteralPath $workflowDir -PathType Container) {
        $workflowFiles = @(Get-ChildItem -LiteralPath $workflowDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        foreach ($wf in $workflowFiles) {
            $bak = $wf.FullName + '.tespeed_wf.bak'
            if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) { continue }
            $currentText = Get-Content -LiteralPath $wf.FullName -Raw -ErrorAction SilentlyContinue
            if ($currentText -notmatch 'TESpeedMiniMaxH3') {
                Write-Host "[SAFE] $($wf.Name) 当前已没有 TE 节点，不用旧备份覆盖它。"
                continue
            }
            $safety = $wf.FullName + '.tespeed_wf.before_revert.bak'
            Copy-Item -LiteralPath $wf.FullName -Destination $safety -Force
            & $python $workflowScript --revert $wf.FullName
            if ($LASTEXITCODE -ne 0) { Write-Warning "工作流回退失败：$($wf.Name)" }
        }
    }

    Write-Host '[3/3] 移除 TE-Speed 自定义节点...'
    if (Test-Path -LiteralPath $plugin -PathType Container) {
        Remove-Item -LiteralPath $plugin -Recurse -Force
    }

    Write-Host ''
    Write-Host 'TE-Speed 已回退。请完全关闭并重新启动 ComfyUI。' -ForegroundColor Green
    Write-Host '原始 .bak 与回退前工作流安全副本会保留，便于人工恢复。'
    [Windows.Forms.MessageBox]::Show(
        "TE-Speed 已回退。`n`n请完全关闭并重新启动 ComfyUI。`n原始备份和回退前安全副本会保留。",
        'TE-Speed 回退完成', 'OK', 'Information') | Out-Null
    exit 0
} catch {
    Write-Host ("回退失败：" + $_.Exception.Message) -ForegroundColor Red
    [Windows.Forms.MessageBox]::Show(
        "TE-Speed 回退没有完成：`n`n$($_.Exception.Message)",
        'TE-Speed 回退失败', 'OK', 'Error') | Out-Null
    exit 1
}
