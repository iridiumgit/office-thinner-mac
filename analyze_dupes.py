#!/usr/bin/env python3
"""
OfficeThinner 分析器 —— 扫描当前已安装的 Microsoft Office for Mac，
按“文件内容”找出跨 App 完全重复的大文件，测算可回收空间。

不修改任何文件，纯只读。
"""
import hashlib
import os
import sys
from collections import defaultdict

BASE = "/Applications"
APPS = [
    "Microsoft Word.app",
    "Microsoft Excel.app",
    "Microsoft PowerPoint.app",
    "Microsoft Outlook.app",
    "Microsoft OneNote.app",
]
PRIORITY = ["Microsoft Word.app", "Microsoft Excel.app",
            "Microsoft PowerPoint.app", "Microsoft Outlook.app",
            "Microsoft OneNote.app"]

CHUNK = 1 << 20


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f}{u}" if u != "B" else f"{n}B"
        n /= 1024
    return f"{n:.1f}TB"


def collect(app):
    """返回 [(relpath, size, relpath_dir)] —— 含 Contents 下的相对路径"""
    root = os.path.join(BASE, app)
    out = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        # 不跟随符号链接目录
        dirnames[:] = [d for d in dirnames
                       if not os.path.islink(os.path.join(dirpath, d))]
        if ".git" in dirnames:
            dirnames.remove(".git")
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            if os.path.islink(p):
                continue
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if not os.path.isfile(p):
                continue
            out.append((os.path.relpath(p, root), st.st_size, st.st_ino))
    return out


def digest(path):
    h = hashlib.blake2b(digest_size=16)
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def main():
    print("=" * 72)
    print("OfficeThinner 重复文件分析（只读）")
    print("=" * 72)

    present = [a for a in APPS if os.path.isdir(os.path.join(BASE, a))]
    missing = [a for a in APPS if a not in present]
    print(f"\n检测到的 Office App：{len(present)} 个")
    for a in present:
        info = os.path.join(BASE, a, "Contents", "Info.plist")
        ver = "?"
        try:
            import plistlib
            with open(info, "rb") as f:
                ver = plistlib.load(f).get("CFBundleShortVersionString", "?")
        except Exception:
            pass
        print(f"  - {a[:-4]:<28} v{ver}")
    if missing:
        print(f"  未安装（跳过）：{', '.join(m[:-4] for m in missing)}")

    # 1. 按 (app, relpath) -> size
    files = {a: collect(a) for a in present}
    total_bytes = 0
    for a in present:
        s = sum(x[1] for x in files[a])
        total_bytes += s
    print(f"\nOffice 三个包内容合计：{human(total_bytes)}")

    # 2. 按 size 分桶，只对可能重复的做哈希
    by_size = defaultdict(list)
    for a in present:
        for rel, size, ino in files[a]:
            if size == 0:
                continue
            by_size[size].append((a, rel, ino))

    candidate = {s: v for s, v in by_size.items() if len(v) > 1}
    cand_files = sum(len(v) for v in candidate.values())
    cand_bytes = sum(s * len(v) for s, v in candidate.items())
    print(f"待哈希候选：{cand_files} 个文件 / {human(cand_bytes)}（同尺寸文件）")

    # 3. 哈希
    by_hash = defaultdict(list)
    done = 0
    for size, items in candidate.items():
        for a, rel, ino in items:
            p = os.path.join(BASE, a, rel)
            try:
                d = digest(p)
            except OSError as e:
                print(f"  ! 无法读取 {p}: {e}", file=sys.stderr)
                continue
            by_hash[(size, d)].append((a, rel, ino))
            done += 1
            if done % 500 == 0:
                print(f"    ...已哈希 {done}/{cand_files}", flush=True)

    # 4. 汇总：只保留跨 App 的重复组
    #    inode 相同 = 已经是硬链接，无需处理
    dir_saving = defaultdict(int)
    total_saving = 0
    dupe_files = 0
    already_linked = 0
    for (size, _), items in by_hash.items():
        inodes = {i for _, _, i in items}
        if len(inodes) < 2:
            already_linked += size * (len(items) - 1)
            continue
        apps = {a for a, _, _ in items}
        if len(apps) < 2:
            continue  # 同 App 内重复，不动
        # 每组保留一个副本（按 PRIORITY），其余可回收
        keeper = min(items, key=lambda x: PRIORITY.index(x[0]))[0]
        for a, rel, ino in items:
            if a == keeper:
                continue
            top = rel.split(os.sep)
            if len(top) > 1:
                key = os.sep.join(top[:3])
            else:
                key = rel
            dir_saving[key] += size
            total_saving += size
            dupe_files += 1

    print("\n" + "=" * 72)
    print("可回收空间明细（TOP 20 目录）")
    print("=" * 72)
    for k, v in sorted(dir_saving.items(), key=lambda x: -x[1])[:20]:
        print(f"  {human(v):>10}  {k}")

    print("\n" + "=" * 72)
    print(f"可回收重复文件：{dupe_files} 个")
    print(f"可回收空间合计：{human(total_saving)}")
    print(f"（另发现已被硬链接共享：{human(already_linked)}）")
    print(f"Office 现占：{human(total_bytes)}  ->  预计降到 {human(total_bytes - total_saving)}")
    print("=" * 72)


if __name__ == "__main__":
    main()
