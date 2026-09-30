# 故障排查：Office 反复索要外部卷的文件访问权限

> 案例日期：2026-09-30　环境：macOS / Office 16.112.4
> 现象：PowerPoint 反复弹出「授予文件访问权限 —— 需要额外的权限才能访问下列文件」，
> 列出外部卷上某个 `.pptx`。用户**已给三个 Office App 打开「完全磁盘访问权限」**，仍无效。

---

## 一、为什么给了「完全磁盘访问权限」也没用

**这个弹窗不是 TCC 授权框，是 App Sandbox 的 Powerbox 对话框。** 两者是相互独立的层：

| | 管什么 | 打开它能解决什么 |
|---|---|---|
| **TCC / 完全磁盘访问** | 受保护位置：桌面、文稿、下载、邮件、其他 App 容器… | 让 App 读到这些位置 |
| **App Sandbox** | 由 entitlements 编译出的沙盒档案；**容器外的一切路径都受它管** | **FDA 完全管不到**，沙盒无法靠用户开关放宽 |

Office for Mac 是**沙盒应用**（`codesign -d --entitlements` 可见
`com.apple.security.app-sandbox = true`），它访问容器外的路径只有三条路：

1. 用户通过「打开/保存」面板**点选**（Powerbox）→ 系统发放临时扩展
2. 用户之前点选过，App 存了 **security-scoped bookmark** → 之后可直接解析
3. App 自带豁免 entitlement（构建期决定，改不了）

另外：**外部卷（`/Volumes/<卷名>`）根本不在 TCC 保护范围内**，
所以对它来说 FDA 是一个完全不相关的开关。

**结论：「给了 FDA 还弹」是必然的，不是故障。**

> 怎么确认自己遇到的是哪一层？看弹窗。TCC 的框标题是「"App" 想访问…」并带系统图标；
> Powerbox 的框是「授予文件访问权限」，且**列出了具体文件路径**。

---

## 二、实际的触发链（实证）

| 证据 | 位置 / 值 |
|---|---|
| Office 的 MRU + Spotlight 索引缓存 | `…/com.microsoft.Powerpoint/Data/Library/Application Support/Microsoft/Office/16.0/spotlightindexer/AggregatedMRUSpotlightIndexedData.json`<br>**修改时间与弹窗时刻一致**，内容引用了那个 pptx |
| 同类 MRU 缓存 | 同目录 `aggmru`、`MruServiceCache` |
| 上次异常退出 | PowerPoint 偏好 `AppExitGraceful = 0` |
| 文档窗口恢复状态 | 偏好键 `NSWindow Frame CUIDocumentShellWindowFrameNameURL/<外部卷路径>/<文件名>` |
| 残留锁文件 | 该卷上 **163 个 `~$` 开头的 Office 锁文件**（2021~2025 异常退出遗留） |
| 下载标记 | 该 pptx 带 `com.apple.quarantine: …;Microsoft PowerPoint;` |

**机制**：PowerPoint 启动时会枚举/索引最近打开的文件（生成缩略图与 MRU），
这些是**自动访问**、不是用户点选 → 拿不到持久授权 → 沙盒每次都问一遍。
上次异常退出（`AppExitGraceful=0`）又让它去恢复上次的文档窗口，进一步加重。

---

## 三、处理办法

### ✅ 已做（本案例）

1. 清理 MRU / Spotlight 索引缓存三件套 —— 备份在 `~/OfficeThinner-pptfix-backup/<时间戳>/`
2. 删除指向外部卷的窗口状态键 —— 原件备份为 `*.plist.bak`
3. `killall cfprefsd` 刷新偏好缓存 → 偏好中该卷的引用数 1 → **0**

> ⚠️ 踩坑：plist 里这个键名以 **`\Uxxxx` 转义形式**存储，`defaults delete "中文键名"` 匹配不上，
> 必须用 **plistlib** 改文件再刷新 cfprefsd。

### 需要用户配合的两步（关键）

1. **改成「点选授权」而不是每次点取消。**
   在 PowerPoint 里用「文件 → 打开 → 其他位置」定位到外部卷上的**目标文件夹**，
   **选中文件夹**确定一次。一直点「取消」就永远记不住 → 每次都会再问。
2. **把正在编辑的文件放内部卷**（如 `~/Documents/工作/`），归档完再挪回外部卷。
   这是唯一能彻底消除跨卷授权问题的办法。

### 可选：清理残留锁文件

外部卷上常年积累的 `~$` 锁文件（异常退出残留）会让 Office 以为文档仍被占用，
反复去碰那些路径。用本仓库的 `clean_office_locks.sh` 处理——
默认干跑列清单，`--clean` 才移入废纸篓。

> **验证时的坑**：卷级废纸篓 `/Volumes/<卷>/.Trashes/<uid>` 的权限是 `d-wx--x--t`
> （**可写不可列**）。`find | wc -l` 会返回误导性的 0，必须用精确路径 `stat` 逐个确认。

### 一个必须留意的分支

如果**点选授权一次之后仍然每次追问**，那就要怀疑是**签名破损导致授权无法持久化**——
本仓库第二/三步裁剪（删语言资源、裁 x86_64）会让签名失效（`codesign --verify` 报
`a sealed resource is missing or invalid`）。这种情况下只有恢复有效签名才能根治，
最直接的办法是用安装镜像重装 Office（代价是裁剪成果全部回退，需重跑三支脚本）。
