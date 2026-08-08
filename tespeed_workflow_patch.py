#!/usr/bin/env python
"""Add or revert TE-Speed-MiniMaxH3 (OSS) wiring inside MiniMax H3 workflow files.

MiniMax H3 workflows ship their sampling chain inside an encapsulated component
(subgraph). This script finds that subgraph and inserts the TESpeedMiniMaxH3
node between UNETLoader and BasicScheduler/BasicGuider:

    UNETLoader.MODEL -> TESpeedMiniMaxH3.model
    TESpeedMiniMaxH3.MODEL -> BasicScheduler.model
    TESpeedMiniMaxH3.MODEL -> BasicGuider.model

Safety model:
  * Before modifying a file, the ORIGINAL bytes are backed up next to it as
    <file>.tespeed_wf.bak (created only once, so it always holds the pristine
    version).
  * --revert restores the backup byte-for-byte. The backup is kept, so
    add/revert can be cycled any number of times.
  * Idempotent: files whose H3 subgraph already contains TESpeedMiniMaxH3 are
    skipped; files without a matching MiniMax H3 component are skipped.
  * Only subgraphs whose exact expected wiring is found are modified; anything
    unexpected is skipped with a warning instead of guessed at.
"""

import argparse
import copy
import json
import sys
from pathlib import Path

BAK_SUFFIX = ".tespeed_wf.bak"
TE_NODE_TYPE = "TESpeedMiniMaxH3"
TE_WIDGETS = [0.12, 0.1, 0.9, 2, "cpu"]

TE_TEMPLATE = {
    "id": 152,
    "type": "TESpeedMiniMaxH3",
    "pos": [0, 0],
    "size": [306.640625, 154],
    "flags": {},
    "order": 19,
    "mode": 0,
    "inputs": [
        {"localized_name": "model", "name": "model", "type": "MODEL", "link": None},
        {"localized_name": "processing_control_value", "name": "processing_control_value", "type": "FLOAT", "widget": {"name": "processing_control_value"}, "link": None},
        {"localized_name": "processing_percent_1", "name": "processing_percent_1", "type": "FLOAT", "widget": {"name": "processing_percent_1"}, "link": None},
        {"localized_name": "processing_percent_2", "name": "processing_percent_2", "type": "FLOAT", "widget": {"name": "processing_percent_2"}, "link": None},
        {"localized_name": "mcs", "name": "mcs", "type": "INT", "widget": {"name": "mcs"}, "link": None},
        {"localized_name": "device", "name": "device", "type": "COMBO", "widget": {"name": "device"}, "link": None},
    ],
    "outputs": [{"localized_name": "模型", "name": "MODEL", "type": "MODEL", "links": []}],
    "properties": {"Node name for S&R": "TESpeedMiniMaxH3"},
    "widgets_values": list(TE_WIDGETS),
}


def iter_json_files(paths):
    for raw in paths:
        p = Path(raw)
        if p.is_dir():
            yield from sorted(p.glob("*.json"))
        elif p.is_file() and p.suffix.lower() == ".json":
            yield p


def read_workflow(path):
    data = path.read_bytes()
    bom = data.startswith(b"\xef\xbb\xbf")
    wf = json.loads(data.decode("utf-8-sig"))
    return wf, bom


def write_workflow(path, wf, bom):
    text = json.dumps(wf, ensure_ascii=False, indent=2)
    path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8"))


def find_h3_subgraphs(wf):
    defs = wf.get("definitions") or {}
    subs = defs.get("subgraphs") or []
    found = []
    for sg in subs:
        if not isinstance(sg, dict):
            continue
        types = {n.get("type") for n in sg.get("nodes", [])}
        if {"UNETLoader", "BasicScheduler", "BasicGuider"} <= types and any(
            t and t.startswith("MiniMaxH3") for t in types
        ):
            found.append(sg)
    return found


def patch_subgraph(sg):
    """Return True=patched, None=already patched, False=unexpected wiring."""
    nodes = {n["id"]: n for n in sg.get("nodes", [])}
    links = {l["id"]: l for l in sg.get("links", [])}

    if any(n["type"] == TE_NODE_TYPE for n in nodes.values()):
        return None

    unet = next(n for n in nodes.values() if n["type"] == "UNETLoader")
    sched = next(n for n in nodes.values() if n["type"] == "BasicScheduler")
    guider = next(n for n in nodes.values() if n["type"] == "BasicGuider")

    l_sched = next((l for l in links.values()
                    if l["origin_id"] == unet["id"] and l["origin_slot"] == 0
                    and l["target_id"] == sched["id"] and l["target_slot"] == 0), None)
    l_guider = next((l for l in links.values()
                     if l["origin_id"] == unet["id"] and l["origin_slot"] == 0
                     and l["target_id"] == guider["id"] and l["target_slot"] == 0), None)
    if l_sched is None or l_guider is None:
        return False

    state = sg.get("state") or {}
    new_id = max([state.get("lastNodeId", 0)] + [n["id"] for n in nodes.values()]) + 1
    new_link = max([state.get("lastLinkId", 0)] + [l["id"] for l in links.values()]) + 1

    te = copy.deepcopy(TE_TEMPLATE)
    te["id"] = new_id
    unet_pos = unet.get("pos") or [0, 0]
    te["pos"] = [unet_pos[0] + 680, unet_pos[1]]
    te["inputs"][0]["link"] = l_sched["id"]
    te["outputs"][0]["links"] = [l_guider["id"], new_link]
    sg["nodes"].append(te)

    l_sched["target_id"] = new_id
    l_sched["target_slot"] = 0
    l_guider["origin_id"] = new_id
    l_guider["origin_slot"] = 0
    sg["links"].append({"id": new_link, "origin_id": new_id, "origin_slot": 0,
                        "target_id": sched["id"], "target_slot": 0, "type": "MODEL"})

    out_links = unet.get("outputs", [{}])[0].get("links") or []
    unet["outputs"][0]["links"] = [x for x in out_links if x != l_guider["id"]]
    sched["inputs"][0]["link"] = new_link

    if isinstance(sg.get("state"), dict):
        sg["state"]["lastNodeId"] = max(sg["state"].get("lastNodeId", 0), new_id)
        sg["state"]["lastLinkId"] = max(sg["state"].get("lastLinkId", 0), new_link)
    return True


def cmd_add(files):
    failures = 0
    for path in files:
        try:
            wf, bom = read_workflow(path)
        except Exception as exc:
            print(f"[SKIP] {path.name}: not a readable workflow JSON ({exc})")
            continue
        subgraphs = find_h3_subgraphs(wf)
        if not subgraphs:
            print(f"[SKIP] {path.name}: no MiniMax H3 component found")
            continue
        results = [patch_subgraph(sg) for sg in subgraphs]
        if all(r is None for r in results):
            print(f"[OK]   {path.name}: TE-Speed already present, nothing to do")
            continue
        if any(r is False for r in results):
            print(f"[WARN] {path.name}: unexpected UNETLoader wiring, left untouched")
            failures += 1
            continue
        backup = path.with_name(path.name + BAK_SUFFIX)
        if not backup.is_file():
            backup.write_bytes(path.read_bytes())
            print(f"[BAK]  {backup.name}: original backed up")
        write_workflow(path, wf, bom)
        print(f"[ADD]  {path.name}: TE-Speed inserted into {sum(1 for r in results if r)} subgraph(s)")
    return failures


def cmd_revert(files):
    failures = 0
    seen = set()
    for path in files:
        backup = path.with_name(path.name + BAK_SUFFIX)
        if path in seen:
            continue
        seen.add(path)
        if not backup.is_file():
            print(f"[SKIP] {path.name}: no backup, nothing to revert")
            continue
        path.write_bytes(backup.read_bytes())
        print(f"[REST] {path.name}: restored byte-for-byte from {backup.name}")
    return failures


def cmd_check(files):
    failures = 0
    for path in files:
        try:
            wf, _ = read_workflow(path)
        except Exception:
            continue
        for sg in find_h3_subgraphs(wf):
            has_te = any(n.get("type") == TE_NODE_TYPE for n in sg.get("nodes", []))
            print(f"[{'ON ' if has_te else 'OFF'}] {path.name}: TE-Speed {'present' if has_te else 'absent'}")
            if not has_te:
                failures += 1
    return failures


def main():
    parser = argparse.ArgumentParser(description="Add/revert TE-Speed wiring in MiniMax H3 workflows")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--add", action="store_true")
    group.add_argument("--revert", action="store_true")
    group.add_argument("--check", action="store_true")
    parser.add_argument("paths", nargs="+", help="workflow .json files and/or directories")
    args = parser.parse_args()

    files = list(iter_json_files(args.paths))
    if not files:
        print("error: no .json files found at the given paths")
        sys.exit(1)

    if args.add:
        failures = cmd_add(files)
    elif args.revert:
        failures = cmd_revert(files)
    else:
        failures = cmd_check(files)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
