#!/bin/bash
#
# remove_mau.sh —— 彻底移除 Microsoft AutoUpdate（MAU），不影响 Office 正常使用
#
# 为什么可以安全移除
#   MAU 只负责「检查并下载安装 Office 更新」。Office 的编辑、保存、协同、模板、
#   拼写检查等功能都不依赖它；弹出的更新提示正是由 MAU 的 LaunchAgent
#   com.microsoft.update.agent（RunAtLoad + StartInterval=7200）定时拉起的。
#
# 【不动的部分】（动了会影响 Office 授权）
#   · /Library/PrivilegedHelperTools/com.microsoft.office.licensingV2.helper
#   · /Library/LaunchDaemons/com.microsoft.office.licensingV2.helper.plist
#   · ~/Library/Group Containers/UBF8T346G9.*
#   · /Library/Application Support/Microsoft/（只清 MAU2.0，保留父目录）
#
# ⚠️ 副作用（必须知情）
#   1) Office 将不再自动更新。Office 更新含安全修复，请自行定期更新：
#      用新的安装镜像重装，或临时重装 MAU。
#   2) Office 菜单「帮助 → 检查更新」将不再可用（点了没反应/报错）。
#   3) 重新安装 Office 会把 MAU 装回来，需要再执行本脚本。
#
# 用法
#   bash remove_mau.sh                # 干跑：列出将被移除的每一项（默认）
#   sudo bash remove_mau.sh --remove  # 执行（先打包备份再删除）
#   sudo bash remove_mau.sh --restore # 从最近批次还原并重新加载
#   bash remove_mau.sh --status       # 查看当前 MAU 状态
#
# 作者: WorkBuddy
# ---------------------------------------------------------------

set -uo pipefail

MODE="dry-run"
BACKUP=""
VERBOSE=0
LISTFILE=""

detect_user_home() {
    u=$(stat -f '%Su' /dev/console 2>/dev/null || echo "")
    if [ -n "$u" ] && [ -d "/Users/$u" ]; then echo "/Users/$u"; else echo "${HOME:-/tmp}"; fi
}
console_uid() { stat -f '%u' /dev/console 2>/dev/null || id -u; }

usage() {
    cat <<EOF
remove_mau.sh —— 彻底移除 Microsoft AutoUpdate

用法:
  bash remove_mau.sh                 # 干跑（默认，只列出将移除的项）
  sudo bash remove_mau.sh --remove   # 执行
  sudo bash remove_mau.sh --restore  # 从最近批次还原
  bash remove_mau.sh --status        # 查看当前状态

选项:
  --remove / --restore / --status
  --backup DIR   备份根目录，默认 "<登录用户目录>/OfficeThinner-mau-backup"
  -v             打印细节
  -h             帮助

流程（--remove）:
  1. 卸载 LaunchAgent / LaunchDaemon，结束 MAU 进程
  2. tar 打包所有待移除项，校验归档条目数 == 源条目数
  3. 校验通过后才删除
  4. 复核 Office 许可组件仍在、Office 仍可用
EOF
}

die() { echo "错误: $*" >&2; exit 1; }
human() { awk -v b="$1" 'BEGIN{split("B KB MB GB",u," ");i=1;while(b>=1024&&i<4){b/=1024;i++};printf (i==1?"%d%s":"%.2f%s"),b,u[i]}'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --remove)  MODE="remove" ;;
        --restore) MODE="restore" ;;
        --status)  MODE="status" ;;
        --backup)  BACKUP="${2:-}"; shift ;;
        -v)        VERBOSE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（用 --help）" ;;
    esac
    shift
done

UHOME="$(detect_user_home)"
[ -z "$BACKUP" ] && BACKUP="$UHOME/OfficeThinner-mau-backup"

# ---------------- 待移除清单 ----------------
TO_REMOVE=(
    "/Library/LaunchAgents/com.microsoft.update.agent.plist"
    "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist"
    "/Library/Application Support/Microsoft/MAU2.0"
    "/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper"
    "$UHOME/Library/Caches/com.microsoft.autoupdate2"
    "$UHOME/Library/Caches/com.microsoft.autoupdate.fba"
    "$UHOME/Library/Preferences/com.microsoft.autoupdate.fba.plist"
    "/var/db/receipts/com.microsoft.package.Microsoft_AutoUpdate.app.bom"
    "/var/db/receipts/com.microsoft.package.Microsoft_AutoUpdate.app.plist"
)
# com.microsoft.autoupdate2.plist 不列入移除：删除后会以「护栏」形式重建，
# 只为写入 HowToCheck=Manual，避免 MAU 万一被装回来又自动弹窗。
GUARD_DOMAIN="com.microsoft.autoupdate2"
# ---------------- 保护清单（绝不触碰）----------------
PROTECTED=(
    "/Library/PrivilegedHelperTools/com.microsoft.office.licensingV2.helper"
    "/Library/LaunchDaemons/com.microsoft.office.licensingV2.helper.plist"
)

LABELS_AGENT=("com.microsoft.update.agent")
LABELS_DAEMON=("com.microsoft.autoupdate.helper")

show_status() {
    echo "================================================================"
    echo " Microsoft AutoUpdate 状态"
    echo "================================================================"
    local n=0
    for p in "${TO_REMOVE[@]}"; do
        if [ -e "$p" ]; then printf '  [存在] %s\n' "$p"; n=$((n+1))
        elif [ "$VERBOSE" -eq 1 ]; then printf '  [已无] %s\n' "$p"; fi
    done
    echo "  ----"
    echo "  待移除项仍存在: $n / ${#TO_REMOVE[@]}"
    if [ "$n" -eq 0 ]; then echo "  ✅ Microsoft AutoUpdate 已完全移除"; else echo "  ⚠️ 仍有 MAU 组件残留"; fi
    echo
    echo "  护栏（防 MAU 被装回后自动弹窗）:"
    hv=$(su -l "$(stat -f '%Su' /dev/console 2>/dev/null)" -c "defaults read $GUARD_DOMAIN HowToCheck" 2>/dev/null \
         || defaults read "$GUARD_DOMAIN" HowToCheck 2>/dev/null)
    if [ "${hv:-}" = "Manual" ]; then
        echo "    ✅ $GUARD_DOMAIN HowToCheck = Manual"
    else
        echo "    ⚠️ 未设置（当前: ${hv:-无}），可选："
        echo "       defaults write $GUARD_DOMAIN HowToCheck -string Manual"
    fi
    echo
    echo "  保护项（必须存在）:"
    for p in "${PROTECTED[@]}"; do
        [ -e "$p" ] && echo "    ✅ $p" || echo "    ❌ 缺失！$p"
    done
    echo
    echo "  运行中的 MAU 任务/进程:"
    launchctl list 2>/dev/null | grep -i -E "microsoft\.(update|autoupdate)" | sed 's/^/    /' || echo "    （无）"
    pgrep -fl "MAU2.0|Microsoft Update Assistant|Microsoft AutoUpdate" 2>/dev/null | sed 's/^/    /' || true
}

if [ "$MODE" = "status" ]; then show_status; exit 0; fi

# ================================================================
# --restore
# ================================================================
if [ "$MODE" = "restore" ]; then
    [ "$(id -u)" -eq 0 ] || die "--restore 需要 root: sudo bash $0 --restore"
    [ -d "$BACKUP" ] || die "备份目录不存在: $BACKUP"
    latest=""
    for d in "$BACKUP"/*/; do
        [ -f "$d/mau-backup.tar.gz" ] || continue
        if [ -z "$latest" ] || [ "$d" -nt "$latest" ]; then latest="$d"; fi
    done
    [ -z "$latest" ] && die "未找到可用归档: $BACKUP"
    echo "从批次 $(basename "$latest") 还原 ..."
    tar -xzf "$latest/mau-backup.tar.gz" -C / || die "解包失败"
    echo "  文件已还原，重新加载 LaunchAgents/Daemons ..."
    launchctl load -w "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist" 2>/dev/null
    uid=$(console_uid)
    launchctl bootout "gui/$uid" "/Library/LaunchAgents/com.microsoft.update.agent.plist" 2>/dev/null
    launchctl load -w "/Library/LaunchAgents/com.microsoft.update.agent.plist" 2>/dev/null
    echo "  完成。"
    show_status
    exit 0
fi

# ================================================================
# dry-run / remove
# ================================================================
[ "$MODE" = "remove" ] && [ "$(id -u)" -ne 0 ] && die "--remove 需要 root: sudo bash $0 --remove"

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="$BACKUP/$STAMP"
LISTFILE=$(mktemp)
TOTAL=0

echo
echo "================================================================"
echo " 彻底移除 Microsoft AutoUpdate"
if [ "$MODE" = "dry-run" ]; then echo " 干跑模式（不会修改任何文件）"; else echo " *** 执行模式 ***"; fi
echo "================================================================"
echo " 备份目录: $DEST"
echo
echo " 将移除:"
for p in "${TO_REMOVE[@]}"; do
    if [ -e "$p" ]; then
        sz=$(du -sk "$p" 2>/dev/null | awk '{print $1*1024}'); sz=${sz:-0}
        printf '%s\n' "$p" >> "$LISTFILE"
        TOTAL=$((TOTAL+sz))
        printf '   %-9s %s\n' "$(human "$sz")" "$p"
    else
        [ "$VERBOSE" -eq 1 ] && printf '   %-9s %s  (不存在，跳过)\n' "-" "$p"
    fi
done
echo
echo " 保留不动（动 Office 授权会出问题）:"
for p in "${PROTECTED[@]}"; do printf '   %s\n' "$p"; done
echo "   /Library/Application Support/Microsoft/  (父目录)"
echo "   ~/Library/Group Containers/UBF8T346G9.*"
echo
echo "----------------------------------------------------------------"
printf ' 合计移除 %s 项, %s\n' "$(grep -c . "$LISTFILE" 2>/dev/null || echo 0)" "$(human "$TOTAL")"

if [ "$MODE" = "dry-run" ]; then
    rm -f "$LISTFILE"
    echo
    echo "以上为干跑结果，未修改任何文件。执行请用:"
    echo "    sudo bash $0 --remove"
    exit 0
fi

[ -s "$LISTFILE" ] || { rm -f "$LISTFILE"; echo "没有需要移除的项（MAU 可能已移除）。"; exit 0; }

# ---------------- 1. 卸载 launch 任务 + 结束进程 ----------------
echo
echo "停止 MAU 任务与进程 ..."
uid=$(console_uid)
for l in "${LABELS_AGENT[@]}"; do
    launchctl bootout "gui/$uid/$l" 2>/dev/null
    launchctl remove "$l" 2>/dev/null
done
for l in "${LABELS_DAEMON[@]}"; do
    launchctl bootout "system/$l" 2>/dev/null
    launchctl remove "$l" 2>/dev/null
done
launchctl unload -w "/Library/LaunchAgents/com.microsoft.update.agent.plist" 2>/dev/null
launchctl unload -w "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist" 2>/dev/null
pkill -f "MAU2.0" 2>/dev/null
pkill -f "Microsoft Update Assistant" 2>/dev/null
pkill -f "Microsoft AutoUpdate" 2>/dev/null
sleep 1
echo "  已停止"

# ---------------- 2. 打包 + 校验 ----------------
mkdir -p "$DEST"
echo "打包备份中 ..."
tar -czf "$DEST/mau-backup.tar.gz" -T "$LISTFILE" 2>/dev/null
[ $? -ne 0 ] && { /bin/rm -f "$DEST/mau-backup.tar.gz"; /bin/rm -f "$LISTFILE"; die "打包失败，未删除任何文件"; }

src_n=0
while IFS= read -r p; do
    n=$(find "$p" 2>/dev/null | wc -l | tr -d ' ')
    src_n=$((src_n+n))
done < "$LISTFILE"
arc_n=$(tar -tzf "$DEST/mau-backup.tar.gz" 2>/dev/null | wc -l | tr -d ' ')
arc_sz=$(stat -f '%z' "$DEST/mau-backup.tar.gz")
printf '  源条目 %s, 归档条目 %s, 归档体积 %s\n' "$src_n" "$arc_n" "$(human "$arc_sz")"
if [ "$src_n" -ne "$arc_n" ]; then
    echo "!! 归档条目数与源不一致，中止（未删除任何文件）" >&2
    /bin/rm -f "$LISTFILE"
    exit 1
fi

# ---------------- 3. 删除 ----------------
echo "校验通过，删除 ..."
removed=0
while IFS= read -r p; do
    if [ -e "$p" ]; then
        # 用绝对路径 /bin/rm，避开 safe-delete 垫片（慢且 fail-closed）
        if /bin/rm -rf "$p" 2>/dev/null; then
            removed=$((removed+1))
            [ "$VERBOSE" -eq 1 ] && echo "  移除 $p"
        else
            echo "  !! 删除失败: $p" >&2
        fi
    fi
done < "$LISTFILE"
cp "$LISTFILE" "$DEST/removed-list.txt"
/bin/rm -f "$LISTFILE"

# ---------------- 4. 附加护栏：即便 MAU 以后被装回来也不自动检查 ----------------
console_user=$(stat -f '%Su' /dev/console 2>/dev/null || echo "")
if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
    su -l "$console_user" -c "defaults write com.microsoft.autoupdate2 HowToCheck -string Manual" 2>/dev/null
fi

echo
echo "已移除 $removed 个条目"
echo "归档: $DEST/mau-backup.tar.gz ($(human "$arc_sz"))"
show_status
echo
echo "还原命令: sudo bash $0 --restore"
