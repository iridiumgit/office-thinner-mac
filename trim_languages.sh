#!/bin/bash
#
# trim_languages.sh —— 移除 Microsoft Office for Mac 中不使用的语言资源（.lproj）
#
# ⚠️ 重要警告
#   本脚本会移除 App 包内的资源文件，这会让 Office 的「Sealed Resources v2」封装校验失效：
#       codesign --verify --strict  ->  "a sealed resource is missing or invalid"
#   主程序二进制未被改动，因此 App 沙盒与 entitlements 仍然有效、App 通常仍能正常启动，
#   但 Apple 的完整性校验不再通过。可能的后果：
#     · 系统在重新评估（如拷贝 App、重装系统更新）时可能提示「已损坏，无法打开」
#     · 每次 Office 更新后需要重新执行（更新会整体替换 App 包）
#
#   为了可回滚，脚本先把待移除的目录打包成压缩归档并校验完整性，校验通过后才删除原文件。
#   --restore 可字节级还原。彻底回滚也可用原始安装镜像重装 Office。
#
# 作者: WorkBuddy
# ---------------------------------------------------------------

set -uo pipefail

BASE="/Applications"
APPS=("Microsoft Word.app" "Microsoft Excel.app" "Microsoft PowerPoint.app")
DEFAULT_KEEP="Base en zh_CN"
MIN_KEEP_BYTES=4096      # 体积小于此值的 .lproj 一律保留（多为空占位）

MODE="dry-run"
KEEP=""
BACKUP=""
VERBOSE=0
LISTFILE=""

detect_user_home() {
    u=$(stat -f '%Su' /dev/console 2>/dev/null || echo "")
    if [ -n "$u" ] && [ -d "/Users/$u" ]; then
        echo "/Users/$u"
    else
        echo "${HOME:-/tmp}"
    fi
}

usage() {
    cat <<EOF
trim_languages.sh —— 移除 Office 用不到的语言资源

用法:
  bash trim_languages.sh                     # 干跑：只统计，不动文件（默认）
  sudo bash trim_languages.sh --remove       # 执行（需 root）
  sudo bash trim_languages.sh --restore      # 从最近批次字节级还原
  bash trim_languages.sh --list              # 列出备份批次

选项:
  --remove            执行移除（默认仅干跑）
  --restore           从备份还原
  --list              列出备份批次
  --keep LIST         保留语言，逗号分隔，默认 "$DEFAULT_KEEP"
                      （Base 是本地化回退基座，建议始终保留）
  --backup DIR        备份根目录，默认 "<登录用户目录>/OfficeThinner-lproj-backup"
  -v                  打印每个被处理的目录
  -h                  帮助

流程（--remove）:
  1. 枚举待移除的 .lproj（跳过保留语言与 <4KB 的占位目录）
  2. tar 打包成 lproj-backup.tar.gz
  3. 校验归档条目数 == 源文件数，不一致则中止且不删任何东西
  4. 校验通过后才删除原目录
EOF
}

die() { echo "错误: $*" >&2; exit 1; }
human() { awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++};printf (i==1?"%d%s":"%.2f%s"),b,u[i]}'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --remove)  MODE="remove" ;;
        --restore) MODE="restore" ;;
        --list)    MODE="list" ;;
        --keep)    KEEP="${2:-}"; shift ;;
        --backup)  BACKUP="${2:-}"; shift ;;
        -v|-verbose) VERBOSE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
    shift
done

[ -z "$KEEP" ] && KEEP="$DEFAULT_KEEP"
[ -z "$BACKUP" ] && BACKUP="$(detect_user_home)/OfficeThinner-lproj-backup"

in_keep() {
    local name="$1" k
    for k in $KEEP; do [ "$name" = "$k" ] && return 0; done
    return 1
}

latest_batch() {
    local latest=""
    for d in "$BACKUP"/*/; do
        [ -f "$d/lproj-backup.tar.gz" ] || continue
        if [ -z "$latest" ] || [ "$d" -nt "$latest" ]; then latest="$d"; fi
    done
    echo "$latest"
}

# ================================================================
# --list / --restore
# ================================================================
if [ "$MODE" = "list" ] || [ "$MODE" = "restore" ]; then
    [ -d "$BACKUP" ] || die "备份目录不存在: $BACKUP"

    if [ "$MODE" = "list" ]; then
        echo "备份目录: $BACKUP"
        found=0
        for d in "$BACKUP"/*/; do
            [ -f "$d/lproj-backup.tar.gz" ] || continue
            found=1
            n=$(grep -c . "$d/removed-list.txt" 2>/dev/null || echo "?")
            printf '  批次 %-20s  %4s 个目录, 归档 %s\n' \
                "$(basename "$d")" "$n" "$(human "$(stat -f '%z' "$d/lproj-backup.tar.gz" 2>/dev/null || echo 0)")"
        done
        [ "$found" -eq 0 ] && echo "  （没有可用批次）"
        exit 0
    fi

    [ "$(id -u)" -eq 0 ] || die "--restore 需要 root，请用: sudo bash $0 --restore"
    latest=$(latest_batch)
    [ -z "$latest" ] && die "未找到任何可用归档: $BACKUP"

    echo "从批次 $(basename "$latest") 还原 ..."
    sz=$(human "$(stat -f '%z' "$latest/lproj-backup.tar.gz")")
    echo "  归档: $latest/lproj-backup.tar.gz ($sz)"
    if tar -xzf "$latest/lproj-backup.tar.gz" -C / ; then
        echo "  还原完成"
    else
        die "tar 解包失败，未做任何清理"
    fi
    echo
    echo "签名校验（还原后应全部通过）:"
    for app in "${APPS[@]}"; do
        [ -d "$BASE/$app" ] || continue
        printf '  %-28s ' "${app%.app}"
        out=$(codesign --verify --strict "$BASE/$app" 2>&1)
        [ -z "$out" ] && echo "通过" || echo "失败: $out"
    done
    exit 0
fi

# ================================================================
# dry-run / remove
# ================================================================
if [ "$MODE" = "remove" ] && [ "$(id -u)" -ne 0 ]; then
    die "--remove 需要 root，请用: sudo bash $0 --remove"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="$BACKUP/$STAMP"

echo
echo "================================================================"
echo " Office 语言资源裁剪"
if [ "$MODE" = "dry-run" ]; then echo " 干跑模式（不会修改任何文件）"; else echo " *** 执行模式 ***"; fi
echo "================================================================"
echo " 保留语言: $KEEP"
echo " 备份目录: $DEST"

LISTFILE=$(mktemp)
TOT_BYTES=0
TOT_DIRS=0
FOUND=0

for app in "${APPS[@]}"; do
    root="$BASE/$app/Contents"
    [ -d "$root" ] || continue
    FOUND=$((FOUND+1))
    app_bytes=0
    app_dirs=0

    while IFS= read -r dir; do
        lang=$(basename "$dir"); lang="${lang%.lproj}"
        in_keep "$lang" && continue
        bytes=$(du -sk "$dir" 2>/dev/null | awk '{print $1*1024}')
        bytes=${bytes:-0}
        [ "$bytes" -lt "$MIN_KEEP_BYTES" ] && continue
        printf '%s\n' "$dir" >> "$LISTFILE"
        app_bytes=$((app_bytes+bytes)); app_dirs=$((app_dirs+1))
        [ "$VERBOSE" -eq 1 ] && echo "  ${MODE/dry-run/将}/处理 ${dir#"$BASE"/} ($(human "$bytes"))"
    done < <(find "$root" -type d -name "*.lproj" 2>/dev/null)

    printf '  %-24s %3d 个语言目录, %s\n' "${app%.app}" "$app_dirs" "$(human "$app_bytes")"
    TOT_BYTES=$((TOT_BYTES+app_bytes)); TOT_DIRS=$((TOT_DIRS+app_dirs))
done

[ "$FOUND" -eq 0 ] && die "在 $BASE 下没找到 Office 应用"
echo "----------------------------------------------------------------"
printf '  合计: %d 个目录, du 口径 %s\n' "$TOT_DIRS" "$(human "$TOT_BYTES")"

if [ "$MODE" = "dry-run" ]; then
    rm -f "$LISTFILE"
    echo
    echo "以上为干跑结果，未修改任何文件。执行请用:"
    echo "    sudo bash $0 --remove --keep \"$KEEP\""
    exit 0
fi

[ "$TOT_DIRS" -eq 0 ] && { rm -f "$LISTFILE"; echo "没有需要移除的目录。"; exit 0; }

# ---------------- 打包 + 校验 ----------------
mkdir -p "$DEST"
echo
echo "打包备份中 ..."
tar -czf "$DEST/lproj-backup.tar.gz" -T "$LISTFILE" 2>/dev/null
tar_rc=$?
if [ "$tar_rc" -ne 0 ]; then
    rm -f "$DEST/lproj-backup.tar.gz" "$LISTFILE"
    die "tar 打包失败（rc=$tar_rc），未删除任何文件"
fi

src_files=0
while IFS= read -r d; do
    n=$(find "$d" 2>/dev/null | wc -l | tr -d ' ')
    src_files=$((src_files+n))
done < "$LISTFILE"
arc_files=$(tar -tzf "$DEST/lproj-backup.tar.gz" 2>/dev/null | wc -l | tr -d ' ')

arc_size=$(stat -f '%z' "$DEST/lproj-backup.tar.gz")
printf '  源条目 %s, 归档条目 %s, 归档体积 %s\n' "$src_files" "$arc_files" "$(human "$arc_size")"
if [ "$src_files" -ne "$arc_files" ]; then
    echo "!! 归档条目数与源不一致，中止（未删除任何文件）" >&2
    echo "   归档保留在 $DEST 供排查" >&2
    rm -f "$LISTFILE"
    exit 1
fi

# ---------------- 校验通过，删除 ----------------
echo "校验通过，删除原目录 ..."
removed=0
while IFS= read -r d; do
    if rm -rf "$d"; then removed=$((removed+1)); else echo "  !! 删除失败: $d" >&2; fi
done < "$LISTFILE"
cp "$LISTFILE" "$DEST/removed-list.txt"
rm -f "$LISTFILE"

echo
echo "已移除 $removed / $TOT_DIRS 个语言目录"
echo "归档: $DEST/lproj-backup.tar.gz ($(human "$arc_size"))"
echo
echo "签名校验（预期失败 —— 这是资源裁剪的必然代价）:"
for app in "${APPS[@]}"; do
    [ -d "$BASE/$app" ] || continue
    printf '  %-28s ' "${app%.app}"
    out=$(codesign --verify --strict "$BASE/$app" 2>&1)
    [ -z "$out" ] && echo "通过（未改动）" || echo "$out"
done
echo
echo "还原命令: sudo bash $0 --restore"
