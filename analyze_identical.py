#!/usr/bin/env python3
"""在当前（已去重 / 已裁语言 / 已裁架构）状态下，找出 SharedSupport 与 Frameworks
里**仍然相同、且还能再优化**的东西。

纯只读。分类：
  A. 跨 App 内容相同但尚未硬链接  -> 可直接再回收
  B. 同 App 内部重复              -> 需要 intra-app 模式
  C. 同尺寸但内容不同（不能动）    -> 说明为什么不能只按尺寸判断
"""
import hashlib
import os
import sys
from collections import defaultdict

APPS = ["Word", "Excel", "PowerPoint"]
BASE = "/Applications/Microsoft %s.app/Contents"
TARGETS = ["Frameworks", "SharedSupport"]
CHUNK = 1 << 20


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}TB"


def digest(p):
    h = hashlib.blake2b(digest_size=16)
    with open(p, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def bucket(rel, top):
    parts = rel.split(os.sep)
    if len(parts) == 1:
        return parts[0]
    return f"{parts[0]}/{parts[1]}"


# ---------------- 采集 ----------------
data = {}          # app -> [(rel, size, ino, mode)]
for app in APPS:
    root = BASE % app
    rows = []
    for dp, dn, fn in os.walk(root):
        parts = dp.split(os.sep)
        if "_CodeSignature" in parts or "_MASReceipt" in parts:
            continue
        for f in fn:
            p = os.path.join(dp, f)
            if os.path.islink(p):
                continue
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if os.path.isfile(p):
                rows.append((os.path.relpath(p, root), st.st_size, st.st_ino,
                             st.st_mode & 0o777))
    data[app] = rows

print("=" * 78)
print(" 当前占用（du / inode 口径）")
print("=" * 78)
for t in TARGETS:
    tot = 0
    for app in APPS:
        rows = [r for r in data[app] if r[0].startswith(t + os.sep)]
        tot += sum(r[1] for r in rows)
        print(f"  {app:<11} Contents/{t}: {len(rows):>6} 个文件, 逻辑 {human(sum(r[1] for r in rows))}")
    print()

# ---------------- A. 跨 App 内容相同但未硬链接 ----------------
print("=" * 78)
print(" A. 跨 App 内容相同、但还没被硬链接（可直接再回收）")
print("=" * 78)

# key = (rel, size) -> {app: (ino, mode)}
idx = defaultdict(dict)
for app in APPS:
    for rel, size, ino, mode in data[app]:
        idx[(rel, size)][app] = (ino, mode)

cand = {k: v for k, v in idx.items()
        if len(v) >= 2 and len({x[0] for x in v.values()}) > 1}
print(f"  同路径同尺寸、inode 不统一 -> 候选 {len(cand)} 组（含同尺寸不同内容的）")

same_size_diff_content = []
linkable = []
for (rel, size), apps in sorted(cand.items(), key=lambda x: -x[0][1]):
    keeper = None
    for app in APPS:
        if app in apps:
            keeper = app
            break
    try:
        h = digest(os.path.join(BASE % keeper, rel))
    except OSError:
        continue
    groups = defaultdict(list)
    for app, (ino, mode) in apps.items():
        p = os.path.join(BASE % app, rel)
        try:
            hh = digest(p)
        except OSError:
            continue
        groups[hh].append((app, ino, mode))
    for hh, items in groups.items():
        if len(items) < 2:
            continue
        if len({i for _, i, _ in items}) == 1:
            continue      # 已经是同一 inode（本不该出现在这里）
        modes = {m for _, _, m in items}
        linkable.append((rel, size, items, len(modes) > 1))
    if len(groups) > 1:
        same_size_diff_content.append((rel, size, len(groups)))

if linkable:
    total = 0
    by_dir = defaultdict(int)
    mode_conflict = []
    for rel, size, items, multi_mode in linkable:
        total += size * (len(items) - 1)
        by_dir[bucket(rel, None)] += size * (len(items) - 1)
        if multi_mode:
            mode_conflict.append((rel, size, [(a, oct(m)) for a, _, m in items]))
    print(f"  可再回收: {human(total)} / {len(linkable)} 组")
    print()
    print("  按目录:")
    for k, v in sorted(by_dir.items(), key=lambda x: -x[1])[:15]:
        print(f"    {human(v):>10}  {k}")
    if mode_conflict:
        print()
        print(f"  ⚠️ 其中权限位不一致、无法硬链接的: {len(mode_conflict)} 组")
        for rel, size, mm in mode_conflict[:8]:
            print(f"    {human(size):>9}  {rel[:60]}")
            for a, m in mm:
                print(f"        {a}: mode={m}")
else:
    print("  ✅ 没有可再回收的跨 App 重复（已全部硬链接）")

if same_size_diff_content:
    n = len(same_size_diff_content)
    b = sum(s for _, s, _ in same_size_diff_content)
    print()
    print(f"  --- 另：同尺寸但内容不同的 {n} 组 / {human(b)}（不可去重，仅作说明）---")
    for rel, size, ng in same_size_diff_content[:5]:
        print(f"    {human(size):>9}  {rel[:64]}  ({ng} 种不同内容)")

# ---------------- B. 同 App 内部重复 ----------------
print()
print("=" * 78)
print(" B. 同一个 App 内部的重复（跨 App 去重覆盖不到）")
print("=" * 78)
grand = 0
for app in APPS:
    for t in TARGETS:
        rows = [r for r in data[app] if r[0].startswith(t + os.sep)]
        by_size = defaultdict(list)
        for rel, size, ino, mode in rows:
            if size >= 4096:
                by_size[size].append((rel, ino))
        by_hash = defaultdict(list)
        for size, items in by_size.items():
            if len(items) < 2:
                continue
            for rel, ino in items:
                try:
                    by_hash[(size, digest(os.path.join(BASE % app, rel)))].append((rel, ino))
                except OSError:
                    pass
        saved = 0
        cnt = 0
        top = []
        for (size, _), items in by_hash.items():
            if len({i for _, i in items}) > 1:
                saved += size * (len(items) - 1)
                cnt += len(items) - 1
                top.append((size * (len(items) - 1), size, len(items), items[0][0]))
        if saved:
            top.sort(reverse=True)
            print(f"  {app:<11} {t:<14} 可回收 {human(saved):>9} ({cnt} 个文件)")
            for s, size, n, rel in top[:2]:
                print(f"        {human(s):>9} ({n} 份 × {human(size)})  {rel[:56]}")
            grand += saved
print()
print(f"  两个目录内部重复合计可回收: {human(grand)}")
