# TE-Speed-MiniMaxH3-OSS

MiniMax H3 的可回滚块缓存加速节点。节点类型为 `TESpeedMiniMaxH3`，通过对 MiniMax H3 DiT 的部分 Transformer blocks 做缓存/残差校正，减少部分去噪步骤的重复计算。

当前一键安装器会在 Windows CI 中直接使用 MiniMaxH3-Installer 固定的 ComfyUI commit `0764232429b8cfb10b79b6f186c8cb23e0b22897` 验证补丁与回退；其他更新版本若核心结构不匹配，补丁脚本会停止而不是强制修改。

## 最简单安装

1. 下载本仓库 ZIP 并解压。
2. 双击 `一键安装TE加速.bat`。
3. 选择你的 **ComfyUI 根目录**（里面应能看到 `main.py`、`comfy`、`custom_nodes`）。
4. 安装器会：
   - 把节点安装到 `ComfyUI\custom_nodes\TE-Speed-MiniMaxH3-OSS`；
   - 自动备份 `comfy\ldm\minimax\model.py` 为 `model.py.te_speed.bak`；
   - 给 MiniMax H3 模型加入 `block_loop` 钩子；
   - 自动扫描 `ComfyUI\user\default\workflows`，仅对结构符合预期的 MiniMax H3 工作流插入 `TESpeedMiniMaxH3`，并建立 `.tespeed_wf.bak` 原始备份。
5. 完成后完全关闭并重新启动 ComfyUI。

需要恢复原状时，双击 `一键卸载并回退TE加速.bat`。

详细说明见 `TE加速_中文使用与风险说明.txt`。

## 手动安装

1. 将本仓库中的 `__init__.py`、`nodes.py`、`patch_model.py`、`tespeed_workflow_patch.py` 放入 `ComfyUI\custom_nodes\TE-Speed-MiniMaxH3-OSS`。
2. 使用 ComfyUI 对应 Python 执行：

```powershell
python patch_model.py --comfy-ui <ComfyUI根目录>
```

3. 可选：给已有工作流自动插入节点：

```powershell
python tespeed_workflow_patch.py --add <工作流文件或目录>
```

4. 重启 ComfyUI。

## 工作流连接

```text
UNETLoader.MODEL
      ↓
TE-Speed-MiniMaxH3 (OSS)
      ├──→ BasicScheduler.model
      └──→ BasicGuider.model
```

## 默认参数

| 参数 | 默认 | 说明 |
| --- | ---: | --- |
| `processing_control_value` | 0.12 | 相邻去噪步 sigma 差较小时允许使用缓存；0 可关闭缓存 |
| `processing_percent_1` | 0.10 | 前 10% 去噪阶段保持完整计算 |
| `processing_percent_2` | 0.90 | 后 10% 去噪阶段保持完整计算 |
| `mcs` | 2 | 最多连续缓存步数；0 可关闭缓存 |
| `device` | auto | 缓存残差位置；低显存可尝试 cpu |
| `cache_depth` | 0.75 | 缓存尾部 block 的比例；越高通常越快，但潜在画质偏差也越大 |

参考工作流和参数下可获得显著提速，曾以约 45% 作为目标/参考值；实际速度取决于 GPU、分辨率、视频时长、采样步数、显存/RAM/offload 和其他节点，**不是固定保证值**。

## 安全设计

- `model.py` 修改前只创建一次原始备份：`model.py.te_speed.bak`。
- 工作流修改前只创建一次逐字节原始备份：`<workflow>.tespeed_wf.bak`。
- 补丁是幂等的：已安装时再次运行不会重复插入。
- 工作流结构不符合预期时会跳过，不猜测接线。
- `patch_model.py --revert` 可恢复核心文件。
- `tespeed_workflow_patch.py --revert ...` 可恢复工作流。

## 注意

该插件会修改 ComfyUI 的 MiniMax H3 核心 `model.py`。ComfyUI 更新后核心代码结构可能变化，因此更新 ComfyUI 后应重新检查；如果补丁锚点不匹配，安装脚本应停止而不是强行修改。加速属于近似缓存计算，在极端运动、细节和长视频场景中可能与全量计算产生差异。