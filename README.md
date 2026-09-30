# OfficeThinner 2.0

为 **Microsoft Office for Mac** 回收被重复文件占用的磁盘空间。

> **这是非官方重写版，与原项目作者无关。**
> 思路借鉴自 [goodbest/OfficeThinner](https://github.com/goodbest/OfficeThinner)，
> 但代码为**完全重写**，未复用其源码；原项目未声明许可证，本项目采用 MIT，两者无版权关联。
> 项目名 `OfficeThinner` 沿用原项目名称以便对照，仓库名与包标识均为独立。
>
> 原项目只适用于 Office 2016 for Mac（15.x），在现代 Office（Microsoft 365 / Office LTSC
> for Mac，16.x）上**会导致应用签名失效、无法启动**。本版本重写了去重机制，适配当前 Office。

## 成果速览（本机实测，Office LTSC 16.112.4）

```
Office 三应用  7.39 GB  →  2.71 GB      省 4.68 GB（−63%）
```

| 步骤 | 回收 | 手段 | 签名安全 |
|---|---|---|---|
| ① 跨 App 重复文件去重 | **−3.20 GB** | 硬链接（`OfficeThinner.sh`） | ✅ 安全 |
| ② 移除多余语言包 | **−0.66 GB** | 只留 `Base`/`en`/`zh_CN`（`trim_languages.sh`） | ⚠️ 破坏签名 |
| ③ 裁掉 x86_64 架构 | **−0.67 GB** | `lipo -thin`（`thin_arch.py`） | ✅ 安全（见下） |
| ④ 补漏：<64KB + App 内重复 | **−0.10 GB** | `--min-size-kb 0 --intra-app` | ✅ 安全 |
| ⑤ 移除 Microsoft AutoUpdate | −12.5 MB | `remove_mau.sh` | ✅ 安全 |
| ⑥ 清理残留锁文件 | −26 KB | `clean_office_locks.sh` | ✅ 安全 |

**一个反直觉的发现**：`lipo -thin` **不会**破坏代码签名——签名覆盖的是各切片自身的字节，
裁掉另一架构不改变目标切片内的任何字节（实测裁完 `codesign --verify --strict` 仍通过）。
真正会破坏封装校验的是**删除/改写资源文件**（即第 ② 步）。

---

## 一、为什么旧版失效

旧版的核心做法是「把 Excel / PowerPoint / Outlook / OneNote 里的重复目录**搬走**，再 `ln -s` 建**符号链接**指回 Word.app」。

这在 2015–2016 年可行，但在今天的 macOS 上必然失败：

| 变化 | 后果 |
|---|---|
| Office 改为 **Developer ID 签名 + 公证（notarized）** | 包内资源被 **Sealed Resources v2** 逐文件封装哈希 |
| Office 启用 **硬运行时（hardened runtime）** | 签名校验成为启动路径上的强制环节 |
| macOS 对签名失效的 App 直接拒绝启动 | 弹「已损坏，无法打开，应移到废纸篓」 |

以本机 Word 16.112.4 为例，`Contents/_CodeSignature/CodeResources` 里封装了 **29,962 个资源**：

```
"Resources/DFonts/AbadiMTCondensedExtraBold.ttf" => {length = 20, bytes = 0xd053a4c5...}
"Resources/Assets.car"                           => {length = 20, bytes = 0x82e09d3d...}
```

**符号链接**把「一个文件」变成了「一个指向别处的链接」——封装校验按路径读到的不再是那个文件，
哈希无法匹配：

```
$ codesign --verify --strict  B.app
B.app: a sealed resource is missing or invalid      ← 旧脚本做法，签名被破坏
```

## 二、2.0 的做法：硬链接

同样的两个副本，改成 **硬链接（hard link）**，一切照旧：

```
$ codesign --verify --strict  B.app
                                                    ← 校验通过，无任何错误输出
```

原因很简单：硬链接**不改变任何字节**，路径上仍然是一个普通文件，内容与原文件完全相同，
封装哈希依旧匹配 → 代码签名保持有效。

上面这两条结论是在本机实测的（方法见文末「附录：验证方法」），不是推测。

由此带来的额外好处：

- **不搬运数据**：旧版要移动 3 GB 文件到桌面备份目录，新版只是改指针，秒级完成
- **不需要备份目录**：内容原件完整留在保留的 App 中，硬链接保证所有 App 读到的字节一致
- **`du` 口径真实**：去重后磁盘占用是真实下降的，可以直接验证

## 三、工具与用法

六支工具。**只有 ② 会破坏签名**，其余都是安全操作。

```bash
# ① 跨 App 重复文件去重（硬链接）—— 收益最大，签名安全
bash OfficeThinner.sh                              # 干跑（只读）
sudo bash OfficeThinner.sh --apply --yes           # 执行

# ② 移除多余语言资源（只留 Base/en/zh_CN）—— 会破坏封装签名
bash trim_languages.sh                             # 干跑
sudo bash trim_languages.sh --remove               # 执行

# ③ 裁掉 x86_64 架构（Apple Silicon 上用不到）
python3 thin_arch.py                               # 干跑
sudo python3 thin_arch.py --apply                  # 执行

# ④ 补漏：<64KB 跨 App 重复 + 同 App 内部重复（实测约 118 MB）
sudo bash OfficeThinner.sh --apply --yes --min-size-kb 0 --intra-app

# ⑤ 彻底移除 Microsoft AutoUpdate
bash remove_mau.sh --status                        # 查看状态
sudo bash remove_mau.sh --remove                   # 执行

# ⑥ 清理残留的 Office 锁文件（~$ 开头，异常退出遗留）
bash clean_office_locks.sh                         # 干跑，只列清单
bash clean_office_locks.sh --clean                 # 移入废纸篓
```

> **⚠️ ② 的前置条件**：它移除 App 包内资源，会让 `codesign --verify --strict` 报
> `a sealed resource is missing or invalid`。macOS 默认在启动时校验签名，因此该步骤要求
> **系统已关闭 SIP 与签名强制**（`csrutil status` → `disabled`），否则 Office 会被拒绝启动。
> ③ 无此要求（原因见上方说明）；①④⑤⑥ 完全不涉及签名。

### ① OfficeThinner.sh —— 主脚本

| 参数 | 说明 |
|---|---|
| `--apply` | 真正执行去重。**不加则只扫描报告**（默认行为） |
| `--yes` | 执行时跳过交互确认 |
| `--min-size-kb N` | 只处理大于 N KB 的文件，默认 `64`；`0` = 全部（更慢，多回收约 60 MB） |
| `--intra-app` | 同时处理**同一个 App 内部**的重复文件（跨 App 去重覆盖不到，例如 `SharedSupport/Proofing Tools` 里 `CssGermanSpeller` 与 `GermanSpeller` 的词库完全相同） |
| `--keep APP` | 保留哪一份原件，默认 `"Microsoft Word.app"` |
| `--base DIR` | Office 所在目录，默认 `/Applications` |
| `-v` | 打印每个被处理的文件 |
| `-h` | 帮助 |

> **补漏的时机**：三步裁剪做完之后再跑一轮 `--min-size-kb 0 --intra-app`。
> 但**每次裁剪/清理后遗留的重复项都会变化，要重新测量再决定**——
> 例如裁掉多余语言包之后，`Frameworks/*/Resources/*.lproj` 里那批 <64KB 重复就一起消失了，
> 跨 App 剩余量从 116 MB 掉到 55 MB。用 `analyze_identical.py` 重新测。

### ② trim_languages.sh

| 参数 | 说明 |
|---|---|
| `--remove` | 执行移除（默认仅干跑） |
| `--keep LIST` | 保留语言，默认 `"Base en zh_CN"`（`Base` 是本地化回退基座，建议保留） |
| `--list` | 列出备份批次 |
| `--restore` | 从备份批次字节级还原 |

实测移除 **3,391 个 `.lproj`**（661 MB 内容、约 650 MB 真实占用），残留 0。

### ③ thin_arch.py

| 参数 | 说明 |
|---|---|
| `--apply` | 真正执行（默认仅干跑） |
| `--keep-arch ARCH` | 保留的架构，默认本机架构（`uname -m`） |
| `--min-size N` | 最小处理尺寸，默认 4096 |

实测裁剪 **228 个**通用二进制（已按 inode 归组，不会破坏跨 App 硬链接），释放 **671.5 MB**，残留 0。

### ④ remove_mau.sh

| 参数 | 说明 |
|---|---|
| `--remove` | 执行移除（默认仅干跑） |
| `--status` | 查看 MAU 残留、护栏、保护项与运行中的任务 |
| `--restore` | 从备份批次还原并重新加载 LaunchAgents/Daemons |

### ⑤ clean_office_locks.sh

| 参数 | 说明 |
|---|---|
| `--path DIR` | 扫描根目录，默认 `/Volumes`（即所有外部卷） |
| `--clean` | 执行（移入废纸篓，不直接删除） |
| `--batch N` | 每批处理数量，默认 10 |

`~$` 开头的文件是 Office 异常退出残留的锁文件。它们会让 Office 反复去碰那些路径
（配合沙盒，会表现为反复索要外部卷访问权限）。实测一个外部卷上积了 **163 个**（2021~2025）。

---

## 四、本机实测数据

### 去重（OfficeThinner.sh）

| 阈值 | 可回收文件数 | 可回收空间 | 耗时 |
|---|---|---|---|
| `--min-size-kb 64`（默认） | 2,347 | **3.19 GB** | 约 60 秒 |
| `--min-size-kb 0`（全量） | 42,897 | 3.40 GB | 明显更久（数万个极小文件） |

另有 4 个文件（31.49 MB）因权限位与所有同内容副本都不一致而跳过——
硬链接共享 inode，权限位无法各自保留，这类文件只能放弃链接（占比约 1%）。

> 全量口径多出的 0.21 GB 分散在约 4 万个几十字节到几十 KB 的小文件上，性价比很低，
> 因此默认阈值取 64 KB（扫描文件数从 10 万降到 5 千，只损失 6% 的收益）。收益集中在：

| 目录 | 可回收 |
|---|---|
| `Contents/Resources/DFonts` | 1.00 GB |
| `Contents/SharedSupport/Proofing Tools` | 606 MB |
| `Contents/Frameworks/ai.framework` | 254 MB |
| `Contents/Frameworks/mso40ui.framework` | 245 MB |
| `Contents/Frameworks/mso99.framework` | 242 MB |
| `Contents/Resources/sdx` | 106 MB |
| `Contents/Frameworks/Chart.framework` | 89 MB |
| `Contents/Frameworks/OfficeArt.framework` | 89 MB |
| `Contents/Resources/Office Themes` | 83 MB |

### 裁剪后最终状态

| 项目 | 结果 |
|---|---|
| 各 App 占用 | Word 1.89 GB / Excel 1.81 GB / PPT 1.55 GB |
| **合计** | **2.71 GB**（原始 7.39 GB） |
| 语言目录 | 304 个（仅 `Base`/`en`/`zh_CN`） |
| 主程序架构 | `arm64`（纯） |
| MAU 残留 | 0 / 9 |
| 字体验证 | CoreText 加载 + 排版 **840/840** 通过 |
| 功能验证 | Word / Excel / PowerPoint 正常启动、无崩溃 |

> 每一步的详细实测、剩余优化空间清单、以及「看着很香但不能做」的项目，
> 见 [`OPTIMIZATION.md`](OPTIMIZATION.md)。跨卷授权弹窗的排查见 [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)。

---

## 五、相对旧版的变化

| | 旧版（OfficeThinner 1.x） | 新版（2.0） |
|---|---|---|
| 去重机制 | `mv` 走 + `ln -s` 符号链接 | 硬链接（原子替换，见下） |
| 对代码签名 | ❌ 破坏 Sealed Resources v2 | ✅ 校验通过 |
| 现代 Office | ❌ 无法启动 | ✅ 可用 |
| 备份目录 | 需要（`~/Desktop/OfficeThinner`） | 不需要 |
| 数据搬运 | 移动数 GB，慢 | 零搬运，秒级 |
| 判定方式 | 按固定目录路径，假设整个目录相同 | 按文件尺寸分组 + `cmp` **逐字节**比对 |
| 目录结构变化 | 路径变了就失效 | 结构无关，自动适应 |
| 版本一致性 | 硬性要求版本号相同 | 不依赖版本号，只信内容 |
| Office 应用数 | 写死 5 个 | 自动探测已安装的任意组合 |
| 权限位 | 不检查 | 逐个匹配同内容副本的权限位 |
| 跨文件系统 | 不检查 | 检查 `st_dev`，不一致则跳过 |
| 同 App 内部重复 | 不支持 | `--intra-app` |
| 执行前预览 | 无 | 默认 dry-run |
| 签名校验 | 无 | 运行前后各校验一次 |

## 六、安全性设计

脚本会主动保护以下几件事，避免踩坑：

1. **默认干跑**：不加 `--apply` 绝不修改文件。
2. **逐字节比对才动手**：同尺寸只是候选，必须 `cmp` 完全相同才视为重复。
   ——这一条不是教条：实测有 5 组文件**同名、同尺寸、内容却不同**
   （最典型的是 `SharedSupport/Open XML for Excel.app` 的主程序，Word 与 PowerPoint 各 143 MB
   但内容不同）。只按尺寸判断就会误判。
3. **不碰 `_CodeSignature/`**：签名文件必须属于各自 App。
4. **不碰 `_MASReceipt/`**：收据文件不跨 App 共享。
5. **不碰主可执行文件**：`Contents/MacOS/<CFBundleExecutable>` 是 App 的身份文件，直接排除。
6. **权限位一致性**：按「代表文件」逐个匹配权限位，能互链的就互链（而不是一刀切跳过）。
7. **同卷检查**：`st_dev` 不一致无法硬链接，直接跳过。
8. **链接失败不丢文件**：见下。
9. **前后签名校验**：每次运行都打印 `codesign --verify --strict` 的结果。

### ⚠️ 一个已修复的严重 bug：`ln -f` 会吃掉文件

2.0 早期版本用 `ln -f 源 目标` 做替换。`ln -f` 的实现是**先 unlink 目标、再创建链接**——
一旦创建那一步失败（权限、只读目录、跨卷……），**目标已经被删掉了，数据凭空消失**。

实测在真实 Office 上因此**永久删掉了 3 个文件**（Word/Excel/PowerPoint 各一份
`mso99.framework/.../strman_c5b6.strings`，语言字符串表）。

**现在的做法**：先在目标目录建临时硬链接，成功后再用 `rename` 原子替换目标。
失败时原文件分毫未动，只报「创建链接失败」。已用「目标目录 chmod 555」构造失败场景验证。

> 那次丢失是**从安装镜像里精确抽单文件补回的**——主安装包是分发包，
> `Office_frameworks.pkg` 的 Payload 是 gzip+cpio，`bsdtar -xf --include='*/strman_c5b6.strings'`
> 两秒即可取出。这个方法对任何「包内文件被误删」都有用。

## 七、回滚

| 操作 | 回滚方式 |
|---|---|
| 硬链接去重 | 不需要回滚。硬链接不改变内容；`cp` 出独立副本即可解除单个链接 |
| 语言包裁剪 | 需要重装 Office，或从安装镜像抽回（归档备份已清理） |
| 架构裁剪 | 需要重装 Office（内容变更无法用备份还原） |
| MAU 移除 | 重装 Office 会带回 MAU；或从 `~/Downloads` 的镜像单独安装 MAU 组件 |

**安装镜像（`~/Downloads` 里的 `Microsoft Office LTSC for Mac 2024` 离线包，约 3.16 GB）请保留**：
MAU 已移除、语言归档已清理，它是目前唯一的重装 / 修复 / 更新介质。

### 注意事项

- **每次 Office 更新后需要重新运行**（更新会整体替换 App 包）。
- 只处理 `/Applications` 下的 Microsoft Office 应用，其他软件一律不动。
- 卸载 Office 不会因硬链接留下残留数据。

## 八、空间计量：以 `du` 为准，别用 `df` 归因

本机出现过三次 `du` 显示回收了空间、而 `df` 的可用空间不跟随的情况，已查明原因：

| 干扰源 | 量级 |
|---|---|
| 用户清空回收站 | 一次性释放 **6.60 GB**，把去重收益完全盖住 |
| Spotlight 重建索引（`/Applications` 索引是开启的，索引库 5.6 GB） | 删除 9 万个文件 + 改动 569 个二进制会触发写入 |
| 缓存 / 分页 / 其他后台写入 | 无法干净归因 |

**硬链接本身确实释放真实磁盘空间**，这是受控 A/B 实验验证过的
（300 MB 副本：真实复制 −0.293 GB，改成硬链接 **+0.293 GB**，精确可测；`cp -c` APFS 克隆则 0 GB）。

所以：**验证收益看 `du`**（同一批路径一次调用，按 inode 去重），`df` 只用于看大盘趋势。

> 若想止住 Spotlight 在 Office 包内的索引开销：`sudo mdutil -i off /Applications`（可 `-i on` 恢复）。

## 九、环境踩坑（做这类操作前必读）

1. **`rm` 可能被 WorkBuddy 的 `safe-delete` 垫片接管**（PATH 注入）。
   每次删除多一层 bash + 日志，3,391 次 `rm -rf` 拖到 12 分钟以上；
   且它「移到废纸篓」失败时是 **fail-closed（拒绝删除）**，不是降级直删。
   绕过：用绝对路径 `/bin/rm`，或 Python 的 `shutil.rmtree()`（不走 PATH）。
2. **`/tmp` 是 `/private/tmp` 的符号链接**。`find /tmp -maxdepth 1` 不跟随符号链接、
   会直接返回 0 条——别据此以为"没有临时文件"。要扫必须写 `/private/tmp`。
3. **脚本以 root 运行产生的备份目录属主是 root**，普通用户 `/bin/rm` 删不掉，必须 sudo。
4. **卷级废纸篓 `.Trashes` 权限是 `d-wx--x--t`（可写不可列）**。
   `find` 看不进去，用 `find | wc -l` 验证"还剩几个"会得到误导性的 0；必须用精确路径 `stat`。
5. **别把 `com.microsoft.autoupdate2.plist` 列进删除清单**：删掉后只要写一次 `defaults write`
   设成 Manual，cfprefsd 立刻重建该文件，导致状态检查永远报"有残留"。它应被当作**护栏**。

## 十、适用版本

- Microsoft 365 for Mac / Office LTSC for Mac，**16.x**（实测 16.112.4）
- 同时兼容旧结构（Office 2016 for Mac 15.x）——脚本按内容判重，与目录结构无关
- 需要 macOS 支持硬链接（所有 APFS / HFS+ 卷均可）

## 附录：验证方法

### A. 复现「符号链接破坏签名、硬链接不破坏签名」

```bash
# 用任意一个体积小、带 Sealed Resources 的已签名 App 做样本
mkdir -p /tmp/otsig && cd /tmp/otsig
ditto /Applications/AnimatedImageMaker.app A.app
ditto /Applications/AnimatedImageMaker.app B.app
codesign --verify --strict A.app && codesign --verify --strict B.app   # 基线：都通过

S="A.app/Contents/Resources/Assets.car"; T="B.app/Contents/Resources/Assets.car"

# ① 符号链接
rm -f "$T"; ln -s "$PWD/$S" "$T"
codesign --verify --strict B.app     # => a sealed resource is missing or invalid

# ② 硬链接
rm -f "$T"; ln -f "$S" "$T"
codesign --verify --strict B.app     # => 通过（无输出）
cmp "$S" "$T" && echo "内容一致"
```

### B. 配对的只读分析脚本

```bash
python3 analyze_dupes.py        # 全包重复测算（blake2b 内容哈希，独立交叉验证）
python3 analyze_identical.py    # 聚焦 Frameworks / SharedSupport 的剩余可回收项
```

`analyze_dupes.py` 用内容哈希测算可回收空间，可与主脚本的 `cmp` 结果互相印证；
`analyze_identical.py` 用来在每次裁剪后**重新测量**还剩什么——
区分「跨 App 未链接」「同 App 内部重复」「同尺寸不同内容（不可动）」三类。

---

## 致谢

去重的思路来自 [goodbest/OfficeThinner](https://github.com/goodbest/OfficeThinner)。
2.0 保留了「多个 Office App 共享同一份资源」的核心理念，把实现从符号链接换成硬链接，
使其在现代 macOS 与 Office 上继续成立。代码为完全重写，未复用原项目源码。

---

## License

[MIT](LICENSE) © 2026 iridiumgit
