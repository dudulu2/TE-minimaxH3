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
    $dialog.Description = '请选择 ComfyUI 根目录（里面能看到 main.py、comfy、custom_nodes）'
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
        throw '用户取消了目录选择。'
    }
    $selected = [IO.Path]::GetFullPath($dialog.SelectedPath)
    if (Test-ComfyRoot $selected) { return $selected }
    $nested = Join-Path $selected 'ComfyUI'
    if (Test-ComfyRoot $nested) { return [IO.Path]::GetFullPath($nested) }
    throw "选择的目录不是可识别的 ComfyUI：$selected"
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
    throw '找不到 Python。MiniMaxH3 一键安装版通常位于 runtime\venv\Scripts\python.exe。'
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
    Write-Host "[3/5] 安装 TE-Speed 节点..."

    $payload = @('__init__.py','nodes.py','patch_model.py','tespeed_workflow_patch.py','README.md','TE加速_中文使用与风险说明.txt')
    foreach ($name in $payload) {
        $source = Join-Path $repoRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "安装包缺少文件：$name" }
        Copy-IfDifferent $source (Join-Path $plugin $name)
    }

    Write-Host "[4/5] 给 MiniMax H3 核心增加可回滚 hook..."
    & $python (Join-Path $plugin 'patch_model.py') --comfy-ui $comfy
    if ($LASTEXITCODE -ne 0) { throw "核心补丁失败，退出码 $LASTEXITCODE。未识别的 ComfyUI 版本不会被强行修改。" }

    $workflowDir = Join-Path $comfy 'user\default\workflows'
    Write-Host "[5/5] 给现有 MiniMax H3 工作流加入 TE 节点..."
    if (Test-Path -LiteralPath $workflowDir -PathType Container) {
        & $python (Join-Path $plugin 'tespeed_workflow_patch.py') --add $workflowDir
        if ($LASTEXITCODE -ne 0) {
            Write-Warning '部分工作流结构与预期不同，已安全跳过；节点与核心 hook 已安装。'
        }
    } else {
        Write-Warning "未找到工作流目录：$workflowDir。你仍可在 ComfyUI 中手动添加 TE-Speed-MiniMaxH3 (OSS) 节点。"
    }

    $state = [ordered]@{
        installed_at = (Get-Date).ToString('o')
        comfy_ui = $comfy
        python = $python
        plugin = $plugin
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $plugin 'te-speed-install.json') -Encoding UTF8

    Write-Host ''
    Write-Host 'TE-Speed 安装完成。请完全关闭并重新启动 ComfyUI。' -ForegroundColor Green
    Write-Host '默认参数是 0.12 / 0.10 / 0.90 / mcs=2 / cache_depth=0.75。'
    Write-Host '如遇到画质、兼容或启动问题，可运行“一键卸载并回退TE加速.bat”。'
    [Windows.Forms.MessageBox]::Show(
        "TE-Speed 安装完成。`n`n请完全关闭并重新启动 ComfyUI 后再使用。`n`n遇到问题可运行“一键卸载并回退TE加速.bat”。",
        'TE-Speed MiniMax H3', 'OK', 'Information') | Out-Null
    exit 0
} catch {
    Write-Host ''
    Write-Host ("安装失败：" + $_.Exception.Message) -ForegroundColor Red
    [Windows.Forms.MessageBox]::Show(
        "TE-Speed 安装没有完成：`n`n$($_.Exception.Message)`n`n请查看控制台信息。",
        'TE-Speed 安装失败', 'OK', 'Error') | Out-Null
    exit 1
}
