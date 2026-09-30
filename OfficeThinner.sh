#!/bin/bash
#
# OfficeThinner 2.0  --  Microsoft Office for Mac 空间瘦身
# ---------------------------------------------------------------
# 原作者 / 原项目:  goodbest  https://github.com/goodbest/OfficeThinner
# 本版本针对现代 Office (Microsoft 365 / Office LTSC for Mac, 16.x) 重写。
#
# 【为什么旧版失效】
#   旧版把重复目录「搬走 + 建符号链接」。现代 Office 是 Developer ID 签名 +
#   公证 (notarized) + 硬运行时 (hardened runtime)，App 包内 29962 个资源
#   被 Sealed Resources v2 逐一用 SHA-1 封装。把被封装的资源换成符号链接，
#   封装校验立即失败：
#       codesign --verify --strict  ->  "a sealed resource is missing or invalid"
#   表现为 App 无法启动 / 提示「已损坏」。
#
# 【本版做法】
#   改用「硬链接」(hard link)。硬链接不改变文件内容，路径上仍是一个普通
#   文件，内容字节 100% 一致 => 封装哈希依然匹配 => 代码签名保持有效。
#   同时硬链接不搬运数据，操作是秒级的，且 du 统计会真实反映去重后的占用。
#
# 【安全设计】
#   - 默认 dry-run，只扫描不修改；必须显式 --apply 才动文件
#   - 只在内容用 cmp 逐字节比对完全相同后才替换
#   - 必须同一文件系统(同 st_dev)才允许硬链接
#   - 权限位不一致的文件跳过，不动
#   - 不触碰 _CodeSignature/（签名文件必须属于各自 App）
#   - 运行前后各做一次 codesign 校验并打印结果
#
# 作者: 本版由 WorkBuddy 适配重写
# 许可: 与原项目一致 (MIT)
# ---------------------------------------------------------------

set -uo pipefail

BASE="/Applications"
MIN_SIZE_KB=64          # 只处理大于该尺寸的文件，小文件收益极低但数量巨大
APPLY=0
ASSUME_YES=0
VERBOSE=0
INTRA=0
KEEP_APP="Microsoft Word.app"

TAB=$'\t'
TMPDIR_OT=""

usage() {
    cat <<EOF
OfficeThinner 2.0 -- 为 Microsoft Office for Mac 回收重复占用空间

用法:
  bash OfficeThinner.sh                 # 干跑：只扫描并报告可回收空间（推荐先跑）
  sudo bash OfficeThinner.sh --apply    # 实际执行（需要 root 权限）

选项:
  --apply            真正执行硬链接去重（默认仅扫描）
  --yes              执行时不交互确认
  --min-size-kb N    只处理大于 N KB 的文件，默认 ${MIN_SIZE_KB}
                     设为 0 可处理全部文件（更慢，收益增量很小）
  --intra-app        同时处理「同一个 App 内部」的重复文件
                     （跨 App 去重覆盖不到，例如 Proofing Tools 里
                      CssGermanSpeller 与 GermanSpeller 的词库完全相同）
  --keep APP         保留哪一份原件，默认 "${KEEP_APP}"
                     可选: "Microsoft Word.app" / "Microsoft Excel.app" /
                           "Microsoft PowerPoint.app" / "Microsoft Outlook.app" /
                           "Microsoft OneNote.app"
  --base DIR         Office 所在目录，默认 "${BASE}"
                     （用于非标准安装路径，或做安全的端到端演练）
  -v, --verbose      打印每个被处理的文件
  -h, --help         显示本帮助

说明:
  仅修改 /Applications 下的 Microsoft Office 应用。不做任何备份目录，
  也不搬移数据 —— 重复文件被删除后直接指向保留的同一份数据。
EOF
}

die() { echo "错误: $*" >&2; exit 1; }
hr()  { printf '%s\n' "----------------------------------------------------------------"; }

cleanup() { [ -n "$TMPDIR_OT" ] && [ -d "$TMPDIR_OT" ] && rm -rf "$TMPDIR_OT"; }
trap cleanup EXIT

# ------------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)        APPLY=1 ;;
        --yes|-y)       ASSUME_YES=1 ;;
        --min-size-kb)  MIN_SIZE_KB="${2:-}"; shift ;;
        --intra-app)    INTRA=1 ;;
        --keep)         KEEP_APP="${2:-}"; shift ;;
        --base)         BASE="${2:-}"; shift ;;
        -v|--verbose)   VERBOSE=1 ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "未知参数: $1（用 --help 查看用法）" ;;
    esac
    shift
done

case "$MIN_SIZE_KB" in
    ''|*[!0-9]*) die "--min-size-kb 需要一个非负整数" ;;
esac


# ------------------------------------------------------------------
# 探测 Office App
# ------------------------------------------------------------------
APP_CANDIDATES=(
    "Microsoft Word.app"
    "Microsoft Excel.app"
    "Microsoft PowerPoint.app"
    "Microsoft Outlook.app"
    "Microsoft OneNote.app"
)

FOUND_APPS=()
for app in "${APP_CANDIDATES[@]}"; do
    [ -d "$BASE/$app" ] && FOUND_APPS+=("$app")
done

[ ${#FOUND_APPS[@]} -eq 0 ] && die "在 $BASE 下没找到任何 Microsoft Office 应用"

# 保留目标必须存在且已安装
KEEP_IDX=-1
for i in "${!FOUND_APPS[@]}"; do
    [ "${FOUND_APPS[$i]}" = "$KEEP_APP" ] && KEEP_IDX=$i
done
if [ "$KEEP_IDX" -lt 0 ]; then
    echo "提示: 保留目标 \"$KEEP_APP\" 未安装，自动改用 \"${FOUND_APPS[0]}\""
    KEEP_APP="${FOUND_APPS[0]}"
fi

[ ${#FOUND_APPS[@]} -lt 2 ] && die "只找到 1 个 Office 应用，没有跨 App 的重复文件可处理"

# --apply 的权限检查：只有当目标确实不可写时才强制要求 root
# （Office 装在 /Applications 时必然需要 sudo；自定义 --base 的可写目录则不需要）
if [ "$APPLY" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    for app in "${FOUND_APPS[@]}"; do
        if [ ! -w "$BASE/$app/Contents" ]; then
            die "--apply 需要 root 权限，请用: sudo bash $0 --apply"
        fi
    done
fi

app_version() {
    /usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
        "$BASE/$1/Contents/Info.plist" 2>/dev/null || echo "?"
}

echo
hr
echo "OfficeThinner 2.0   (干跑模式，不会修改任何文件)"
[ "$APPLY" -eq 1 ] && echo "                    *** 执行模式 ***"
hr
echo "保留原件: $KEEP_APP"
echo "尺寸阈值: > ${MIN_SIZE_KB} KB"
[ "$INTRA" -eq 1 ] && echo "额外处理: 同一 App 内部重复 (--intra-app)"
echo
echo "检测到的 Office 应用:"
for app in "${FOUND_APPS[@]}"; do
    printf '  - %-28s v%s\n' "${app%.app}" "$(app_version "$app")"
done

# 版本一致性只做提示：硬链接靠内容比对，不依赖版本号
ref_ver=$(app_version "${FOUND_APPS[0]}")
for app in "${FOUND_APPS[@]:1}"; do
    v=$(app_version "$app")
    [ "$v" != "$ref_ver" ] && echo "  注意: ${app%.app} 版本 v$v 与 ${FOUND_APPS[0]%.app} v$ref_ver 不同，重复项可能变少"
done

app_disk_usage() {
    du -sk "$@" 2>/dev/null | awk '{s+=$1} END {printf "%.2f GB", s/1048576}'
}
APP_ABS=()
for app in "${FOUND_APPS[@]}"; do APP_ABS+=("$BASE/$app"); done

echo
echo "Office 当前总占用: $(app_disk_usage "${APP_ABS[@]}")"
echo "(参考) 卷可用空间:"
df -h "$BASE" | awk 'NR==2 {printf "  %s 可用 %s / 共 %s\n", $9, $4, $2}'

sig_check() {
    local label="$1" rc=0 app out
    echo
    echo "代码签名校验 ($label):"
    for app in "${APP_ABS[@]}"; do
        out=$(codesign --verify --strict "$app" 2>&1)
        if [ -z "$out" ]; then
            printf '  %-30s 通过\n' "${app##*/}"
        else
            printf '  %-30s 失败: %s\n' "${app##*/}" "$out"
            rc=1
        fi
    done
    return $rc
}

sig_check "修改前"

# ------------------------------------------------------------------
# 执行前确认（交互式终端才提示；非交互环境必须显式 --yes）
# ------------------------------------------------------------------
if [ "$APPLY" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
    if [ -t 0 ]; then
        printf '\n将对以上 %d 个应用执行硬链接去重，是否继续？[y/N] ' "${#FOUND_APPS[@]}"
        read -r ans || ans=""
        ans=$(printf '%s' "$ans" | tr -d '\r\n\t ')   # 容忍回车/空白
        case "$ans" in
            y|Y|yes|YES) echo ;;
            *)           echo "已取消，未修改任何文件。"; exit 0 ;;
        esac
    else
        die "非交互环境（无终端）下执行 --apply 必须显式加 --yes"
    fi
fi

# ------------------------------------------------------------------
# 收集文件清单
# ------------------------------------------------------------------
TMPDIR_OT=$(mktemp -d "${TMPDIR:-/tmp}/officethinner.XXXXXX") || die "无法创建临时目录"
RAW="$TMPDIR_OT/raw.tsv"       # app_idx \t size \t dev \t ino \t mode \t path
INTEREST="$TMPDIR_OT/sizes.txt"

echo
echo "正在扫描文件（阈值 > ${MIN_SIZE_KB} KB）..."

for i in "${!FOUND_APPS[@]}"; do
    root="$BASE/${FOUND_APPS[$i]}/Contents"
    # 主可执行文件不参与去重：内容虽相同，但它是 App 的身份文件，
    # 被原地改写时连带风险最大，且现实中的 Office 各 App 主程序本就不同。
    mainexe=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - \
        "$root/Info.plist" 2>/dev/null || true)
    mainexe_path=""
    [ -n "$mainexe" ] && mainexe_path="$root/MacOS/$mainexe"

    find "$root" -type f \
        -not -path "*/_CodeSignature/*" \
        -not -path "*/_MASReceipt/*" \
        -size "+$(( MIN_SIZE_KB * 1024 ))c" \
        -exec stat -f "%z${TAB}%d${TAB}%i${TAB}%Lp${TAB}%N" {} + 2>/dev/null \
        | awk -F"$TAB" -v idx="$i" -v exe="$mainexe_path" '
            $5 ~ /\/_CodeSignature\// { next }
            $5 ~ /\/_MASReceipt\//    { next }
            exe != "" && $5 == exe    { next }
            { print idx "\t" $0 }' >> "$RAW"
done

total_files=$(wc -l < "$RAW" | tr -d ' ')
echo "共收集到 $total_files 个候选文件（已排除 _CodeSignature）"

# 找出「值得逐字节比对的尺寸值」：
#   ① 跨 App：同一尺寸出现在 >=2 个不同 App
#   ② --intra-app：同一尺寸在同一个 App 内出现 >=2 次
awk -F"$TAB" -v intra="$INTRA" '
{
    key = $2
    ak = key SUBSEP $1
    if (!(ak in seen)) { seen[ak]=1; mask[key] += 2^$1 }   # 用 2 的幂标记出现过的 App
    pc[ak]++
    if (pc[ak] >= 2) dup[key] = 1
}
END {
    for (k in mask) {
        m = mask[k]
        # 不是 2 的幂 => 至少出现在 2 个 App => 跨 App
        cross = (m != 1 && m != 2 && m != 4 && m != 8 && m != 16)
        if (cross || (intra == "1" && (k in dup))) print k
    }
}
' "$RAW" | sort -n > "$INTEREST"

interest_n=$(wc -l < "$INTEREST" | tr -d ' ')
echo "其中 $interest_n 个尺寸值存在跨 App 重复，进入逐字节比对"

if [ "$interest_n" -eq 0 ]; then
    echo
    echo "没有发现跨 App 的重复文件，无需处理。"
    exit 0
fi

# 只保留感兴趣的尺寸行，并按尺寸排序，便于顺序分组
filtered="$TMPDIR_OT/filtered.tsv"
awk -F"$TAB" 'NR==FNR { want[$1]=1; next } ($2 in want)' "$INTEREST" "$RAW" \
    | sort -t"$TAB" -k2,2n > "$filtered"

# ------------------------------------------------------------------
# 逐组比对 -> 硬链接
# ------------------------------------------------------------------
linked=0
saved=0
skipped_mode=0
skipped_mode_bytes=0
skipped_dev=0
failed=0
SAVED_LOG="$TMPDIR_OT/saved.log"

echo
if [ "$APPLY" -eq 1 ]; then
    echo "开始去重 ..."
else
    echo "干跑比对中（不修改文件）..."
fi

group_n=0
declare -a G_PATH=() G_APP=() G_MODE=() G_DEV=() G_INO=()

process_group() {
    local n=${#G_PATH[@]}
    [ "$n" -lt 2 ] && return 0

    group_n=$((group_n+1))
    [ $((group_n % 200)) -eq 0 ] && printf '  ...已处理 %d 组\n' "$group_n"

    # 每组保留优先级最高的 App 中的那一份
    local keep_idx=0 prio_best=999 p i
    for i in $(seq 0 $((n-1))); do
        p=${#FOUND_APPS[@]}
        for j in "${!FOUND_APPS[@]}"; do
            [ "${FOUND_APPS[$j]}" = "${G_APP[$i]}" ] && p=$j
        done
        if [ "$p" -lt "$prio_best" ]; then prio_best=$p; keep_idx=$i; fi
    done

    # reps: 代表文件池。每个代表代表一类「内容 + 文件系统」，
    #       权限位在真正链接时才比对（硬链接共享 inode，权限位无法各自保留）
    local -a reps=("$keep_idx")

    for i in $(seq 0 $((n-1))); do
        [ "$i" -eq "$keep_idx" ] && continue

        # 找出所有内容完全一致的代表（跨文件系统的先排除：无法硬链接）
        local -a cand=()
        local r
        for r in "${reps[@]}"; do
            [ "${G_DEV[$i]}" = "${G_DEV[$r]}" ] || continue
            cmp -s "${G_PATH[$i]}" "${G_PATH[$r]}" && cand+=("$r")
        done

        if [ ${#cand[@]} -eq 0 ]; then
            # 跨卷且无同卷代表 -> 记一次跳过
            if [ "${G_DEV[$i]}" != "${G_DEV[$keep_idx]}" ]; then
                [ "$VERBOSE" -eq 1 ] && echo "  跳过(跨卷): ${G_PATH[$i]}"
                skipped_dev=$((skipped_dev+1))
            fi
            reps+=("$i")          # 内容独特，成为新的代表
            continue
        fi

        # 优先选权限位一致的代表；硬链接共享 inode，权限位无法各自保留
        local match=-1
        for r in "${cand[@]}"; do
            if [ "${G_MODE[$i]}" = "${G_MODE[$r]}" ]; then
                match=$r
                break
            fi
        done

        if [ "$match" -lt 0 ]; then
            [ "$VERBOSE" -eq 1 ] && echo "  跳过(权限位 ${G_MODE[$i]} 与所有同内容件不一致): ${G_PATH[$i]}"
            skipped_mode=$((skipped_mode+1))
            skipped_mode_bytes=$((skipped_mode_bytes+$(stat -f '%z' "${G_PATH[$i]}" 2>/dev/null || echo 0)))
            reps+=("$i")   # 作为该「内容+权限」类别的代表，供后续同权限的副本链接
            continue
        fi

        # 已经是同一个 inode（之前跑过）-> 无需操作
        if [ "${G_INO[$i]}" = "${G_INO[$match]}" ]; then
            continue
        fi

        local bytes
        bytes=$(stat -f '%z' "${G_PATH[$i]}" 2>/dev/null) || bytes=0
        local rel="${G_PATH[$i]#"$BASE"/}"
        rel="${rel#*/Contents/}"
        local d1 d2 rest
        case "$rel" in
            */*) d1="${rel%%/*}"; rest="${rel#*/}"; d2="${rest%%/*}" ;;
            *)   d1="$rel"; d2="" ;;
        esac
        local bucket="Contents/$d1"
        [ -n "$d2" ] && bucket="Contents/$d1/$d2"

        if [ "$APPLY" -eq 1 ]; then
            # 【安全替换】绝不能用 `ln -f`：它会先 unlink 目标、再创建链接，
            #   一旦创建链接这一步失败（权限/配额/跨卷），目标文件已被删除 —— 永久丢文件。
            # 正确做法：先在目标目录里建一个临时硬链接，成功后再用 rename 原子替换。
            #   任何一步失败，原文件都完好无损。
            local _tmp="${G_PATH[$i]}.otlink.$$"
            if ln "${G_PATH[$match]}" "$_tmp" 2>/dev/null; then
                if mv -f "$_tmp" "${G_PATH[$i]}" 2>/dev/null; then
                    linked=$((linked+1))
                    saved=$((saved+bytes))
                    printf '%s\t%s\n' "$bytes" "$bucket" >> "$SAVED_LOG"
                    [ "$VERBOSE" -eq 1 ] && echo "  链接 ${G_PATH[$i]}"
                else
                    /bin/rm -f "$_tmp" 2>/dev/null
                    echo "  !! 替换失败（原文件未动）: ${G_PATH[$i]}" >&2
                    failed=$((failed+1))
                fi
            else
                echo "  !! 创建链接失败（原文件未动）: ${G_PATH[$i]}" >&2
                failed=$((failed+1))
            fi
        else
            linked=$((linked+1))
            saved=$((saved+bytes))
            printf '%s\t%s\n' "$bytes" "$bucket" >> "$SAVED_LOG"
        fi
    done
}

# 顺序读取 filtered.tsv，按尺寸分组
cur_size=""
while IFS="$TAB" read -r app_idx size dev ino mode path; do
    if [ "$size" != "$cur_size" ]; then
        process_group
        G_PATH=(); G_APP=(); G_MODE=(); G_DEV=(); G_INO=()
        cur_size="$size"
    fi
    G_PATH+=("$path")
    G_APP+=("${FOUND_APPS[$app_idx]}")
    G_MODE+=("$mode")
    G_DEV+=("$dev")
    G_INO+=("$ino")
done < "$filtered"
process_group

# ------------------------------------------------------------------
# 结果
# ------------------------------------------------------------------
human() { awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++};printf (i==1?"%d%s":"%.2f%s"),b,u[i]}'; }

echo
hr
echo "可回收重复文件数: $linked"
echo "可回收空间:       $(human $saved)"
[ "$skipped_mode" -gt 0 ] && echo "因权限位不一致跳过: $skipped_mode 个 ($(human $skipped_mode_bytes))"
[ "$skipped_dev" -gt 0 ]  && echo "因跨文件系统跳过:   $skipped_dev"
[ "$failed" -gt 0 ]       && echo "链接失败:           $failed"

if [ -s "$SAVED_LOG" ]; then
    echo
    echo "按目录汇总 (TOP 15):"
    awk -F"$TAB" '{ s[$2]+=$1 } END { for (k in s) printf "%d\t%s\n", s[k], k }' "$SAVED_LOG" \
        | sort -rn | head -15 \
        | while IFS="$TAB" read -r b d; do
            printf '  %10s  %s\n' "$(awk -v x="$b" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(x>=1024&&i<5){x/=1024;i++};printf (i==1?"%d%s":"%.2f%s"),x,u[i]}')" "$d"
          done
fi

if [ "$APPLY" -eq 0 ]; then
    echo
    hr
    echo "以上为干跑结果，未修改任何文件。"
    echo "确认无误后执行:"
    echo "    sudo bash $0 --apply"
    hr
    exit 0
fi

echo
echo "Office 处理后总占用: $(app_disk_usage "${APP_ABS[@]}")"
df -h "$BASE" | awk 'NR==2 {printf "卷可用空间: %s / 共 %s\n", $4, $2}'

if sig_check "修改后"; then
    echo
    hr
    echo "完成。所有 Office 应用的代码签名校验通过，内容未发生任何变化。"
    echo "备份说明: 本版不产生备份 —— 被删除的只是重复副本，内容原件完整保留在"
    echo "          $KEEP_APP 中，硬链接保证各 App 读到的字节完全一致。"
    echo "回滚方式: 重新运行 Microsoft AutoUpdate 更新 Office，即可恢复标准安装形态"
    echo "          （更新会整体替换 App 包，硬链接自动失效）。"
    echo "注意: 每次 Office 更新后需要重新运行本脚本。"
    hr
else
    echo
    echo "!!! 警告: 有应用的签名校验未通过。"
    echo "!!! 请重新安装该应用，并保留本脚本的输出以便排查。"
    exit 1
fi
