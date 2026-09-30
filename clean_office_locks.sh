#!/bin/bash
#
# clean_office_locks.sh —— 清理指定卷上残留的 Office 锁文件（~$ 开头）
#
# 什么是 ~$ 文件
#   Word / Excel / PowerPoint 在打开文档时会在**文档同目录**创建 `~$<文件名>` 锁文件，
#   用于标记「该文档正被某个用户打开」。正常保存退出时会被删除。
#   崩溃 / 强制退出 / 断电后会残留下来（一留就是好几年）。
#
# 为什么值得清理
#   · Office 会把这些残留当成「文档仍被占用」，反复去访问那些路径；
#     若文档在外部卷上，App Sandbox 每次都要向用户索取文件访问权限（反复弹窗）。
#   · 打开文档时可能出现「文件正被 XX 使用」的误报。
#
# 安全设计
#   · 默认干跑，只列清单；--clean 才动
#   · 一律**移入废纸篓**，绝不直接删除（同卷 .Trashes 优先，退回 ~/.Trash）
#   · 分批（默认每批 10 个）执行，每批核对成功数，任一批不完全成功立即停止
#   · 执行前必须确认没有 Office 进程在运行
#   · 写出清单文件，记录每个文件的原始路径与去向
#
# 用法
#   bash clean_office_locks.sh                      # 干跑（默认扫描 /Volumes 下所有卷）
#   bash clean_office_locks.sh --clean              # 执行
#   bash clean_office_locks.sh --path /Volumes/Work --clean
#   bash clean_office_locks.sh --batch 20           # 每批 20 个
#
# 作者: WorkBuddy
# ---------------------------------------------------------------

set -uo pipefail

SCAN_PATH="/Volumes"
MODE="dry-run"
BATCH=10
REPORT_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --clean)  MODE="clean" ;;
        --path)   SCAN_PATH="${2:-}"; shift ;;
        --batch)  BATCH="${2:-}"; shift ;;
        --report) REPORT_DIR="${2:-}"; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
    shift
done

[ -d "$SCAN_PATH" ] || { echo "错误: 路径不存在: $SCAN_PATH" >&2; exit 1; }
case "$BATCH" in ''|*[!0-9]*) echo "错误: --batch 需要正整数" >&2; exit 1 ;; esac

STAMP=$(date +%Y%m%d-%H%M%S)
[ -z "$REPORT_DIR" ] && REPORT_DIR="$HOME/OfficeThinner-lockcleanup"
DEST_TS="$REPORT_DIR/$STAMP"

human() { awk -v b="$1" 'BEGIN{split("B KB MB GB",u," ");i=1;while(b>=1024&&i<4){b/=1024;i++};printf (i==1?"%d%s":"%.2f%s"),b,u[i]}'; }

# ---------------- 0. Office 是否在运行 ----------------
office_running() {
    pgrep -f "Microsoft \(Word\|Excel\|PowerPoint\)" >/dev/null 2>&1
}

echo
echo "================================================================"
echo " 清理残留 Office 锁文件（~\$ 开头）"
if [ "$MODE" = "dry-run" ]; then echo " 干跑模式（不会移动任何文件）"; else echo " *** 执行模式：移入废纸篓 ***"; fi
echo "================================================================"
echo " 扫描路径: $SCAN_PATH"

if office_running; then
    echo
    echo " ⚠️ 检测到 Office 正在运行。请先退出 Word / Excel / PowerPoint 再执行，"
    echo "    否则可能误判「正在使用的锁文件」。"
    [ "$MODE" = "clean" ] && exit 1
fi

# ---------------- 1. 扫描 ----------------
LIST=$(mktemp)
find "$SCAN_PATH" -name '~$*' -type f 2>/dev/null | sort > "$LIST"
COUNT=$(wc -l < "$LIST" | tr -d ' ')
TOTAL=0
while IFS= read -r f; do
    s=$(stat -f '%z' "$f" 2>/dev/null || echo 0); TOTAL=$((TOTAL+s))
done < "$LIST"

echo " 找到锁文件: $COUNT 个, 合计 $(human "$TOTAL")"
if [ "$COUNT" -eq 0 ]; then rm -f "$LIST"; echo; echo " 无需清理。"; exit 0; fi

echo
echo " 明细（前 20 条）:"
head -20 "$LIST" | while IFS= read -r f; do
    printf '   %s  %s\n' "$(stat -f '%Sm' -t '%Y-%m-%d' "$f" 2>/dev/null)" "$f"
done
[ "$COUNT" -gt 20 ] && echo "   ...（其余 $((COUNT-20)) 条见清单文件）"

if [ "$MODE" = "dry-run" ]; then
    echo
    echo "---------------------------------------------------------------"
    echo " 以上为干跑结果，未移动任何文件。执行请用:"
    echo "     bash $0 --path \"$SCAN_PATH\" --clean"
    rm -f "$LIST"
    exit 0
fi

# ---------------- 2. 废纸篓目标 ----------------
UID_N=$(id -u)
VOL_TRASH="$SCAN_PATH/.Trashes/$UID_N"
USE=""
if mkdir -p "$VOL_TRASH" 2>/dev/null && [ -w "$VOL_TRASH" ]; then
    USE="$VOL_TRASH"
else
    mkdir -p "$HOME/.Trash" 2>/dev/null
    if [ -w "$HOME/.Trash" ]; then USE="$HOME/.Trash"; fi
fi
[ -z "$USE" ] && { echo "错误: 找不到可写的废纸篓" >&2; rm -f "$LIST"; exit 1; }
echo
echo " 废纸篓: $USE"

mkdir -p "$DEST_TS"
cp "$LIST" "$DEST_TS/removed-locks.txt"

# ---------------- 3. 分批移动 + 逐批核对 ----------------
echo
echo " 分批移动（每批 $BATCH 个）..."
moved=0
failed=0
batch_no=0
declare -a BATCH_FILES=()

flush_batch() {
    [ ${#BATCH_FILES[@]} -eq 0 ] && return 0
    batch_no=$((batch_no+1))
    local ok=0 n=0 f base target
    for f in "${BATCH_FILES[@]}"; do
        n=$((n+1))
        base=$(basename "$f")
        target="$USE/$base"
        # 避免重名覆盖
        if [ -e "$target" ]; then target="$USE/${base}.${STAMP}"; fi
        if mv "$f" "$target" 2>/dev/null && [ ! -e "$f" ]; then
            ok=$((ok+1))
            printf '%s\t%s\n' "$f" "$target" >> "$DEST_TS/moved.tsv"
        else
            failed=$((failed+1))
            echo "   !! 批次 $batch_no 移动失败: $f" >&2
        fi
    done
    printf '  批 %-3s 本批 %2s 个 -> 成功 %2s\n' "$batch_no" "$n" "$ok"
    if [ "$ok" -ne "$n" ]; then
        echo "   !! 批次 $batch_no 未全部成功，立即停止（已成功 $moved 个）" >&2
        return 1
    fi
    moved=$((moved+ok))
    return 0
}

while IFS= read -r f; do
    BATCH_FILES+=("$f")
    if [ ${#BATCH_FILES[@]} -ge "$BATCH" ]; then
        flush_batch || { rm -f "$LIST"; exit 1; }
        BATCH_FILES=()
    fi
done < "$LIST"
flush_batch || { rm -f "$LIST"; exit 1; }

rm -f "$LIST"

# ---------------- 4. 复核 ----------------
left=$(find "$SCAN_PATH" -name '~$*' -type f 2>/dev/null | wc -l | tr -d ' ')
echo
echo "---------------------------------------------------------------"
echo " 已移入废纸篓: $moved 个"
[ "$failed" -gt 0 ] && echo " 失败: $failed 个"
echo " 扫描路径上剩余 ~\$ 文件: $left 个"
echo " 清单: $DEST_TS/removed-locks.txt"
echo " 去向: $DEST_TS/moved.tsv"
echo
echo " 还原：从废纸篓 ${USE} 把文件拖回原路径（清单里有原始路径）"
echo " 确认无误后可清空废纸篓。"
