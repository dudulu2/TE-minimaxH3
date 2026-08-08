#!/usr/bin/env python
"""Install/revert the MiniMax H3 block_loop hooks used by TE-Speed.

Safety rules:
- Before patching an unmodified ComfyUI model.py, keep a matching stock backup
  at model.py.te_speed.bak.
- If ComfyUI was upgraded and an older backup no longer matches the new stock
  model.py, preserve the old backup as *.stale-* and refresh the active backup.
- --revert only restores a backup when the current model.py still contains the
  TE-Speed hook. If ComfyUI already replaced the file with a stock/new version,
  it will NOT overwrite that newer file with an old backup.
"""

import argparse
import ast
import hashlib
import re
import shutil
from datetime import datetime
from pathlib import Path

TARGET = Path("comfy/ldm/minimax/model.py")
BACKUP_SUFFIX = ".te_speed.bak"

COMMON_ROOTS = [
    Path("."), Path(".."), Path("ComfyUI"), Path("../ComfyUI"),
    Path("G:/ComfyUI-aki-v3/ComfyUI"), Path("C:/ComfyUI"),
    Path("D:/ComfyUI"), Path("E:/ComfyUI"),
    Path("C:/Users/Administrator/ComfyUI"),
]

RUN_BLOCKS_METHOD = '''    def _run_blocks(self, h, t_emb, mod_segments, rope_freqs, transformer_options, start=0, end=None):
        patches_replace = transformer_options.get("patches_replace", {})
        blocks_replace = patches_replace.get("dit", {})
        end = len(self.blocks) if end is None else end
        prefetch_queue = comfy.model_prefetch.make_prefetch_queue(list(self.blocks[start:end]), h.device, transformer_options)
        for i in range(start, end):
            block = self.blocks[i]
            comfy.model_prefetch.prefetch_queue_pop(prefetch_queue, h.device, block)
            if ("double_block", i) in blocks_replace:
                def block_wrap(args):
                    return {"img": block(args["img"], args["t_emb"], args["mod_segments"], args["rope_freqs"],
                                         transformer_options=args["transformer_options"])}
                h = blocks_replace[("double_block", i)](
                    {"img": h, "t_emb": t_emb, "mod_segments": mod_segments, "rope_freqs": rope_freqs,
                     "transformer_options": transformer_options},
                    {"original_block": block_wrap})["img"]
            else:
                h = block(h, t_emb, mod_segments, rope_freqs, transformer_options=transformer_options)
        if prefetch_queue is not None:
            comfy.model_prefetch.prefetch_queue_pop(prefetch_queue, h.device, None)
        return h

'''

HOOK_LOOP = '''        # blocks (TE-Speed-MiniMaxH3-OSS hook)
        patches_replace = transformer_options.get("patches_replace", {})
        blocks_replace = patches_replace.get("dit", {})
        cache_ranges = [(a, b) for a, b, kind in layout.segments if kind in ("audio", "video")]
        if ("block_loop", 0) in blocks_replace:
            def block_loop_wrap(args):
                return {"img": self._run_blocks(args["img"], args["t_emb"], args["mod_segments"], args["rope_freqs"],
                                                args["transformer_options"], args.get("start", 0), args.get("end"))}
            h = blocks_replace[("block_loop", 0)](
                {"img": h, "t_emb": t_emb, "mod_segments": mod_segments, "rope_freqs": rope_freqs,
                 "transformer_options": transformer_options, "cache_ranges": cache_ranges, "block_count": len(self.blocks)},
                {"original_block": block_loop_wrap})["img"]
        else:
            h = self._run_blocks(h, t_emb, mod_segments, rope_freqs, transformer_options)
'''

LOOP_RE = re.compile(
    r'        patches_replace = transformer_options\.get\("patches_replace", \{\}\)\n'
    r'        blocks_replace = patches_replace\.get\("dit", \{\}\)\n'
    r'        prefetch_queue = comfy\.model_prefetch\.make_prefetch_queue\('
    r'list\(self\.blocks\), device, transformer_options\)\n'
    r'.*?'
    r'        if prefetch_queue is not None:\n'
    r'            comfy\.model_prefetch\.prefetch_queue_pop\(prefetch_queue, device, None\)\n',
    re.DOTALL,
)

FORWARD_ANCHOR = "    def forward(self, x, timestep, context,"
RUN_BLOCKS_ANCHOR = "    def _run_blocks(self, h, t_emb, mod_segments, rope_freqs, transformer_options, start=0, end=None):"


def find_model_file(comfy_ui=None):
    if comfy_ui is not None:
        p = Path(comfy_ui)
        for candidate in (p / TARGET, p / "ComfyUI" / TARGET):
            if candidate.is_file():
                return candidate
        raise SystemExit(f"error: no MiniMax H3 model file under {p}")
    for root in COMMON_ROOTS:
        for candidate in (root / TARGET, root / "ComfyUI" / TARGET):
            if candidate.is_file():
                return candidate
    raise SystemExit("error: could not locate ComfyUI; pass --comfy-ui <ComfyUI root>")


def hook_status(text):
    return RUN_BLOCKS_ANCHOR in text and '("block_loop", 0) in blocks_replace' in text


def digest(data):
    return hashlib.sha256(data).hexdigest()[:12]


def ensure_matching_backup(target):
    backup = target.with_name(target.name + BACKUP_SUFFIX)
    current = target.read_bytes()
    if not backup.is_file():
        shutil.copy2(target, backup)
        print(f"[BAK] stock core saved: {backup}")
        return backup

    old = backup.read_bytes()
    if old == current:
        return backup

    # Current is stock but changed since the old backup: likely a ComfyUI update.
    # Preserve the stale backup and make a new backup matching this version.
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    stale = backup.with_name(backup.name + f".stale-{stamp}-{digest(old)}")
    shutil.copy2(backup, stale)
    shutil.copy2(target, backup)
    print(f"[BAK] ComfyUI core changed; old backup preserved as: {stale}")
    print(f"[BAK] active backup refreshed for current core: {backup}")
    return backup


def apply_patch(text):
    if not LOOP_RE.search(text):
        raise SystemExit(
            "error: stock MiniMax H3 block loop was not recognized. "
            "ComfyUI may have changed; no modification was made."
        )
    text = LOOP_RE.sub(HOOK_LOOP, text, count=1)
    if RUN_BLOCKS_ANCHOR not in text:
        if FORWARD_ANCHOR not in text:
            raise SystemExit("error: MiniMaxH3Model.forward anchor not found; no modification was made.")
        text = text.replace(FORWARD_ANCHOR, RUN_BLOCKS_METHOD + FORWARD_ANCHOR, 1)
    return text


def main():
    parser = argparse.ArgumentParser(description="Install/revert TE-Speed MiniMax H3 core hooks")
    parser.add_argument("--comfy-ui", help="ComfyUI root directory")
    parser.add_argument("--revert", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    target = find_model_file(args.comfy_ui)
    text = target.read_text(encoding="utf-8")
    backup = target.with_name(target.name + BACKUP_SUFFIX)

    if args.check:
        print(f"[{'ON' if hook_status(text) else 'OFF'}] TE-Speed core hook: {target}")
        return

    if args.revert:
        if not hook_status(text):
            print("[SAFE] Current model.py has no TE-Speed hook; leaving it untouched.")
            print("       This avoids restoring an obsolete backup after a ComfyUI update.")
            return
        if not backup.is_file():
            raise SystemExit(f"error: hook is present but backup is missing: {backup}")
        shutil.copy2(backup, target)
        print(f"[RESTORE] core restored from matching backup: {backup}")
        return

    if hook_status(text):
        print(f"[OK] TE-Speed hooks already present: {target}")
        return

    ensure_matching_backup(target)
    patched = apply_patch(text)
    ast.parse(patched)
    if not hook_status(patched):
        raise SystemExit("error: internal verification failed; no modified file was written")
    target.write_text(patched, encoding="utf-8")
    print(f"[PATCH] TE-Speed core hook installed: {target}")
    print("Restart ComfyUI before using TESpeedMiniMaxH3.")


if __name__ == "__main__":
    main()
