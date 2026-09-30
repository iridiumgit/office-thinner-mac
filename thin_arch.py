#!/usr/bin/env python3
"""thin_arch.py —— 裁掉 Office for Mac 中当前机器用不到的 CPU 架构

背景
  Office 的 Mach-O 都是通用二进制（x86_64 + arm64）。在 Apple Silicon 上，
  x86_64 那一半永远不会被加载，纯属占盘。

为什么安全
  · 每个切片带自己的签名，`lipo -thin` 只是把目标切片原样取出来，
    切片内字节不变 → 该切片的代码签名仍然有效（实测 codesign --verify 通过）。
  · 保留 arm64 切片，本机行为完全不变（不涉及 Rosetta）。
  · 跨 App 硬链接的文件按 inode 去重，只裁一次并重新建立硬链接，
    不会破坏 OfficeThinner 已完成的去重成果。

用法
  python3 thin_arch.py                      # 干跑（默认，只统计）
  sudo python3 thin_arch.py --apply         # 执行
  sudo python3 thin_arch.py --apply --keep-arch arm64
  sudo python3 thin_arch.py --apply --min-size 4096   # 最小处理尺寸，默认 4KB
"""
import argparse
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

APPS = ["Microsoft Word.app", "Microsoft Excel.app", "Microsoft PowerPoint.app"]
BASE = "/Applications"

FAT_MAGICS = (0xCAFEBABE, 0xCAFEBABF)   # fat / fat64（大端）
CPU_NAMES = {
    0x01000007: "x86_64",
    0x0100000C: "arm64",
    0x00000007: "i386",
    0x0000000C: "arm",
    0x01000012: "arm64_32",
}


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}TB"


def fat_info(path):
    """返回 [(架构名, 切片字节数), ...]；非通用二进制返回 None"""
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError:
        return None
    if len(head) < 8:
        return None
    if struct.unpack(">I", head[:4])[0] not in FAT_MAGICS:
        return None
    n = struct.unpack(">I", head[4:8])[0]
    if not (1 < n <= 16):
        return None
    archs = []
    try:
        with open(path, "rb") as f:
            f.seek(8)
            for _ in range(n):
                e = f.read(20)
                if len(e) < 20:
                    return None
                cpu = struct.unpack(">I", e[:4])[0]
                size = struct.unpack(">I", e[12:16])[0]
                archs.append((CPU_NAMES.get(cpu, hex(cpu)), size))
    except OSError:
        return None
    return archs


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--apply", action="store_true", help="真正执行（默认仅干跑）")
    ap.add_argument("--keep-arch", default=None, help="保留的架构，默认本机架构")
    ap.add_argument("--min-size", type=int, default=4096, help="最小处理文件尺寸，默认 4096")
    ap.add_argument("--base", default=BASE, help="Office 所在目录")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    keep = args.keep_arch or subprocess.run(["uname", "-m"], capture_output=True,
                                             text=True).stdout.strip()
    if args.apply and os.geteuid() != 0:
        print("错误: --apply 需要 root", file=sys.stderr)
        return 1

    print("=" * 78)
    print(" 裁掉用不到的 CPU 架构")
    print("=" * 78)
    print(f" 保留架构: {keep}")
    print(f" 模式: {'*** 执行 ***' if args.apply else '干跑（不修改任何文件）'}")
    print()

    # ---------- 收集：按 inode 归组，处理跨 App 硬链接 ----------
    groups = {}          # (dev, ino) -> {"paths": [...], "size": int, "archs": [(name,sz)], "mode":int}
    scanned = 0
    for app in APPS:
        root = os.path.join(args.base, app, "Contents")
        if not os.path.isdir(root):
            continue
        for dp, dn, fn in os.walk(root):
            if "_CodeSignature" in dp.split(os.sep):
                continue
            for f in fn:
                p = os.path.join(dp, f)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                if os.path.islink(p) or not os.path.isfile(p) or st.st_size < args.min_size:
                    continue
                scanned += 1
                inf = fat_info(p)
                if not inf:
                    continue
                names = [a for a, _ in inf]
                if keep not in names or len(names) < 2:
                    continue
                key = (st.st_dev, st.st_ino)
                g = groups.get(key)
                if g:
                    g["paths"].append(p)
                else:
                    groups[key] = {"paths": [p], "size": st.st_size,
                                   "archs": inf, "mode": st.st_mode & 0o7777,
                                   "uid": st.st_uid, "gid": st.st_gid}
    print(f" 扫描 {scanned:,} 个文件，其中 {len(groups)} 个通用二进制需要裁剪"
          f"（已按 inode 去重跨 App 硬链接）")
    print()

    # ---------- 预估收益 ----------
    est = 0
    per_arch = {}
    for key, g in groups.items():
        keep_sz = sum(s for a, s in g["archs"] if a == keep)
        drop_sz = sum(s for a, s in g["archs"] if a != keep)
        est += drop_sz
        for a, s in g["archs"]:
            if a != keep:
                per_arch[a] = per_arch.get(a, 0) + s
    for a, s in sorted(per_arch.items(), key=lambda x: -x[1]):
        print(f"   裁掉 {a:<10} 可省 {human(s)}")
    print(f"   预估合计可省: {human(est)}")
    print()

    if not args.apply:
        print(" 以上为干跑结果，未修改任何文件。执行请用:")
        print("     sudo python3 thin_arch.py --apply")
        return 0

    # ---------- 执行 ----------
    done = 0
    freed = 0
    failed = 0
    tmpdir = tempfile.mkdtemp(prefix="thin_arch.")
    try:
        for key, g in groups.items():
            path = g["paths"][0]
            try:
                before = os.lstat(path).st_size
                out = os.path.join(tmpdir, "thin.out")
                if os.path.exists(out):
                    os.unlink(out)
                r = subprocess.run(["lipo", "-thin", keep, path, "-output", out],
                                   capture_output=True, text=True)
                if r.returncode != 0 or not os.path.exists(out):
                    failed += 1
                    if args.verbose:
                        print(f"   !! lipo 失败 {path}: {r.stderr.strip()}", file=sys.stderr)
                    continue
                after = os.lstat(out).st_size
                # 保持权限/属主，替换主副本
                os.chmod(out, g["mode"])
                try:
                    os.chown(out, g["uid"], g["gid"])
                except OSError:
                    pass
                shutil.move(out, path)

                # 其余硬链接指向新的（已裁剪的）inode，保住去重成果
                for other in g["paths"][1:]:
                    try:
                        if os.lstat(other).st_ino == os.lstat(path).st_ino:
                            continue
                        os.unlink(other)
                        os.link(path, other)
                    except OSError as e:
                        print(f"   !! 重建硬链接失败 {other}: {e}", file=sys.stderr)

                done += 1
                freed += before - after
                if args.verbose:
                    print(f"   {human(before - after):>9}  {path}")
            except Exception as e:                       # noqa: BLE001
                failed += 1
                print(f"   !! 处理失败 {path}: {e}", file=sys.stderr)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print(f" 已裁剪 {done} 个通用二进制, 实际释放 {human(freed)}")
    if failed:
        print(f" 失败 {failed} 个（原文件未改动）")
    print()

    # ---------- 复核 ----------
    print(" 复核（随机抽查 5 个）:")
    import random
    sample = random.sample(list(groups.values()), min(5, len(groups)))
    for g in sample:
        p = g["paths"][0]
        archs = subprocess.run(["lipo", "-archs", p], capture_output=True, text=True).stdout.strip()
        nl = os.lstat(p).st_nlink
        print(f"   {os.path.relpath(p, os.path.join(args.base, APPS[0], 'Contents'))[:58]:<58} "
              f"架构={archs} links={nl}")
    print()
    print(" 注意: Office 更新后会恢复成通用二进制，需要重新运行本脚本。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
