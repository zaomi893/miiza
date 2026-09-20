# OnePlus 15（PLK110）HMBIRD II 自定义 GKI

本仓库在一加 15 已验证可启动的 Android 16 / Linux 6.12.23 GKI 构建链上，集成 ReSukiSU，并保留 ColorOS 风驰调速器（HMBIRD II）。目标固件为国行 `PLK110_16.0.9.400(CN01)`；不要用于 CPH2747 等非国行机型。

## 当前状态

- 内核版本：`6.12.23-android16-5-gb2a876903b49-ab14541642-4k`
- 实机：一加 15 `PLK110`，活动槽位 `boot_a`
- 系统：`PLK110_16.0.9.400(CN01)`
- Root：ReSukiSU，可正常取得 root shell
- 风驰：支持原厂 `oplus_bsp_sched_ext.ko`，游戏启动后由 `hmbird_II` 接管
- 安装包：AnyKernel3 替换 boot 中的 GKI Image；序列号锁启用时还会在当前槽 `init_boot` 中清理旧构建标记，并安装首启阶段助手。不会修改 `vendor_boot` 或 `vendor_dlkm`

2026-09-07 已对同一台手机分别永久刷入原厂 boot 和本仓库生成的 boot，并在《王者荣耀》前台运行时采样：

| 检查项 | 原厂 boot | 自定义 boot |
| --- | --- | --- |
| 开机后空闲状态 | `sched_ext=disabled` | `sched_ext=disabled` |
| 游戏运行后 | `sched_ext=enabled` | `sched_ext=enabled` |
| 当前调度器 | `hmbird_II` | `hmbird_II` |
| `enable_seq` | `1` | `1`（重复启动会递增） |
| `nr_rejected` | `0` | `0` |
| 游戏帧率配置 | `144` | `144` |
| 保留 CPU | `0xf0` → `0xe0` | `0xf0` → `0xe0` |
| 王者线程规则 | 已下发 | 已下发 |
| 原厂 `rust_binder.ko` | 正常加载 | 正常加载，`Unknown symbol=0` |

这里的“已下发”不是只看模块是否加载：`oplusHmbirdBpfManager` 已向内核注册，进入游戏后 `/proc/sys/hmbird_II/prefer_cpu`、`prefer_idle` 和 `prefer_preempt` 出现 `UnityMain`、`UnityGfxDeviceW`、`Job.worker` 等游戏线程规则，同时内核记录 `gpa pid set`、`scx enabled` 和 heartbeat。这说明风驰已接管并实际收到游戏云控调度配置。

## 风驰版本入口

每个入口优先使用目标机型自己的官方内核模块仓库和分支。官方同步版本 `16.0.7` 及以上归为金标，低于 `16.0.7` 归为紫标。唯一例外是尚未公开当前 MT6993 模块树的 Find X9 金标：它使用与实机原厂模块源码指纹完全一致的官方同步点，并仍按 MTK 配置只生成元数据。构建只消费 `vendor/oplus/kernel/cpu` 中的官方风驰源码，并用同一次 GKI 编译提取匹配的 `.BTF` / `.BTF_ids`：

| 机型 | 版本 | 官方同步版本 | 工作流 |
| --- | --- | --- | --- |
| 一加 15 | 金标 | `PLK110_16.0.9.400(CN01)`，[`5ab2a689`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850/commit/5ab2a689ff87d7d28c511f1762cf41c1b90d965a) | `fastbuild_6.12.23_oneplus_15_hmbird_gold.yml` |
| 一加 15 | 紫标 | `PLK110_16.0.5.701(CN01)`，[`7fb7abf`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850/commit/7fb7abf097a18c6e2ad2fb9d18876b095898e87f) | `fastbuild_6.12.23_oneplus_15_hmbird_purple.yml` |
| 一加 15T | 金标 | `PLZ110_16.0.8.300(CN01)`，[`d447f71`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850/commit/d447f713d6403f707a2910383495f4ada98cfa4d) | `fastbuild_6.12.38_oneplus_15t_hmbird_gold.yml` |
| 一加 15T | 紫标 | `PLZ110_16.0.4.603(CN01)`，[`bc8d91d`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850/commit/bc8d91d1e146be96d2e27bebe8f753f82bdebeee) | `fastbuild_6.12.38_oneplus_15t_hmbird_purple.yml` |
| Ace6T | 金标 | `PLR110_16.0.9.400(CN01)`，[`c198db9`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8845/commit/c198db99380d7f268894229b8e3ab1deaff8ba79) | `fastbuild_6.12.38_oneplus_ace6t_hmbird_gold.yml` |
| Ace6T | 紫标 | `PLR110_16.0.5.702(CN01)`，39 ID，[`5bc6b8a`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8845/commit/5bc6b8ab8671f68c7754ea42bda91b660ff0ac53) | `fastbuild_6.12.38_oneplus_ace6t_hmbird_purple.yml` |
| OnePlus Pad 3 Pro | 紫标 | `OPD2513_16.0.6.103(CN01)`，[`8be53e8`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850/commit/8be53e8b737a83a33512d5e0106cccb010a5c24c) | `fastbuild_6.12.58_hmbird_purple.yml` |
| OPPO Find X9 系列 | 金标 | `PLG110_16.0.10.501(CN01)` 实机模块对应的 39-ID 源码修订，[`c198db9`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8845/commit/c198db99380d7f268894229b8e3ab1deaff8ba79) | `fastbuild_6.12.23_mtk_hmbird_gold.yml` |
| OPPO Find X9 系列 | 紫标 | `16.0.1.301/302`，[`4d505a4`](https://github.com/oppo-source/android_kernel_modules_and_devicetree_oppo_mt6993/commit/4d505a4292dab3176a45fec66dc85debc362e24c) | `fastbuild_6.12.23_mtk_hmbird_purple.yml` |
| OnePlus Ace 6 Ultra | 金标 | `PMB110_16.0.9.400(CN01)`，[`2cc7f46`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_mt6993/commit/2cc7f4606b65a9ede42030ee82614dd845b665a1) | `fastbuild_6.12.58_mtk_hmbird_gold.yml` |
| OnePlus Ace 6 Ultra | 紫标 | `PMB110_16.0.6.103(CN01)`，[`366500c`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_mt6993/commit/366500c5f2c1b45764722d20b2d923b3816e7bda) | `fastbuild_6.12.58_mtk_hmbird_purple.yml` |

一加 15 的 common GKI 底座仍取自本仓库配置的 `6.12.23` 源码分支，避免换成当前无法在该机启动的官方 common 版本；一加 15T 的底座继续跟随 `oneplus/sm8850_b_16.0_oneplus_15t` 已验证启动链。其他入口保留各自已验证启动的内核底座和 Clang `r536225` 构建链。金标、紫标只改变风驰模块源码提交，不改变内核底座、启动基线或序列号锁。`7fb7abf` 与 `bc8d91d` 不再是当前分支头，工作流按完整 SHA 精确获取这两个历史同步点。

Pad 3 Pro 的 SM8850 官方分支目前只有 `16.0.6.103`，因此仅保留紫标入口，不再复用 15T 的跨机型提交。Find X9 的 OPPO 官方 MT6993 分支只到 `16.0.1.301/302`；紫标继续使用它，金标则使用与 `16.0.10.501` 实机模块 `srcversion` 和39项 kfunc 布局完全一致的官方同步点。

除一加 15/15T 外，各入口的底座均固定到 `zaominn` 账号中对应迁移分支的当前完整提交，并在编译前通过 GitHub API 核对分支 HEAD、Linux 版本、SoC 与模块平台；任一项漂移或串线都会直接停止构建：

| 机型 | SoC / 平台 | 迁移内核源码 | 风驰平台配置 |
| --- | --- | --- | --- |
| Ace 6T | SM8845 / 高通 | `zaominn/android_kernel_common_oneplus_sm8845` | `Makefile.qcom` / `CONFIG_OPLUS_SYSTEM_KERNEL_QCOM` |
| Pad 3 Pro | SM8850 / 高通 | `zaominn/android_kernel_common_oneplus_sm8850` | `Makefile.qcom` / `CONFIG_OPLUS_SYSTEM_KERNEL_QCOM` |
| Ace 6 Ultra | MT6993 / 天玑 | `zaominn/android_kernel_oneplus_mt6993` | `Makefile.mtk` / `CONFIG_OPLUS_SYSTEM_KERNEL_MTK` |
| Find X9 | MT6993 / 天玑 | `zaominn/android_kernel_oppo_mt6993` | `Makefile.mtk` / `CONFIG_OPLUS_SYSTEM_KERNEL_MTK` |

## 风驰兼容方式

手机继续加载原厂 `vendor_dlkm` 中的模块代码，本仓库不会用自编译 `.ko` 覆盖原厂模块。构建流程会使用同一次 GKI 编译的 BTF ID 空间编译官方风驰源码，只提取生成模块的 `.BTF` 和 `.BTF_ids` 元数据，再写入 Image 中预留的固定槽位；模块装载时仅对已核对身份的原厂风驰模块使用这份匹配元数据。

另有 103 个国行固件模块携带与自定义 GKI 不兼容的旧式 split-BTF。内核只按仓库内固定名单忽略这些模块的错误 BTF，而不改模块代码、符号 CRC 或 KMI，也不会宽泛屏蔽所有模块的 BTF 检查。风险是名单与其他固件版本不一定一致，因此本仓库只声明支持 `PLK110_16.0.9.400(CN01)`；系统升级后必须重新验证。

天玑入口使用 `hmbird_module/Makefile.mtk` 与 `CONFIG_OPLUS_SYSTEM_KERNEL_MTK`；Ace 6 Ultra 取 OnePlusOSS MT6993 模块仓库，Find X9 的旧版元数据取 `oppo-source` MT6993 模块仓库。Find X9 当前 OTA 尚无对应 MT6993 公开提交，因此仅用与其实机模块 `srcversion` 完全一致的 Ace6T 提交补齐新版元数据，并仍按 MTK 配置编译；手机不会加载该构建产物的代码。由于这些仓库未提供可提取指纹的预编译 `.ko`，MTK 配置下的兼容层使用“精确模块名 + `.BTF_ids` 结构”校验。高通入口使用独立的 `hmbird_module/Makefile.qcom` 与 `CONFIG_OPLUS_SYSTEM_KERNEL_QCOM`，并保留原有 BTF 哈希指纹校验。

Find X9 `16.0.10.501` 与 Ace6T `16.0.10.500` 的实机原厂模块都报告 `srcversion=CAD3D00952B4ECFE53162C5`，并暴露 39 个 kfunc ID；旧公开 Find X9 源码只生成33个。因此金标和紫标保持为两个独立工作流，构建时分别强制校验39项或33项，不填充未知 ID，也不替换 `vendor_dlkm` 中的原厂代码。

## 原厂模块兼容日志

- `rust_binder: Unknown symbol` 是原厂模块与自定义 GKI 的 Rust `core/kernel/bindings` crate 哈希不同导致的。实机逐项核对的 76 个引用在本 GKI 中都有同名、同签名导出；兼容桥只在设备序列号已验证、模块名为 `rust_binder` 且 `scmversion=gb2a876903b49` 时替换 3 个精确 crate 哈希，并继续执行内核原有的 modversion CRC 检查。构建也会确认全部映射目标存在，避免静默放宽模块解析。实机已确认模块成功加载且 `Unknown symbol=0`。
- `hb_bpf_cpuperf_set -> kernel/sched/sched.h:1705` WARN 在原厂 boot 和自定义 boot 上均可复现，且两者风驰均正常接管、`nr_rejected=0`。这是原厂风驰路径的行为，不通过隐藏日志或更改调度逻辑来冒险“修复”。

## 构建与设备序列号锁

在 GitHub Actions 手动运行 `6.12.23 欧加真OKI内核快速构建`，必须填写 `device_serial`。允许 6–64 位字母、数字、点、下划线、冒号和连字符。

每次构建生成独立的 32 字节随机盐和一次性启动标记令牌，将 `SHA-256(随机盐 || 序列号)` 写入 Image，不保存明文序列号。AK3 中的 `serial_lock/` 只是刷机资源目录；其中 `build-token` 是 64 位十六进制的本次构建随机令牌，不是序列号。刷入时 AK3 不读取、创建、删除或改写 `init_boot` 标记，只创建 `/data/adb/service.d/service_log.sh` 一次性脚本，临时运行资源放在 `/data/local/tmp/serial_lock_stage`，不创建 KernelSU/Magisk 模块或 `module.prop`。启动时由内核直接校验序列号：匹配时不安排重启并向一次性脚本报告 `verified`；不匹配时由内核自行启动固定 180 秒重启。`service_log` 是唯一允许改写标记的组件：匹配且已有标记时删除标记，没有标记则完全不写 `init_boot`；不匹配时写入本次构建标记，已有旧标记也覆盖。无论结果如何，退出时都会删除自身和整个临时目录。标记成功时才启用下一次启动的早期拒绝。风驰 BTF 兼容入口仍要求序列号已经验证。

这是高风险的实验性防误刷机制。刷机环境必须能写入 `/data/adb` 和 `/data/local/tmp`，否则 AK3 会在刷 boot 前中止；`service_log` 运行时还必须能读写当前槽 `init_boot`。序列号不匹配时，内核本身保证本次启动在 180 秒后重启。只有标记成功写入并回读一致时，下一次启动才进入早期拒绝。

GitHub Release 日志和刷机包注释会按要求显示本次输入的绑定序列号。该机制能阻止误刷并提高直接二进制修改门槛，但客户端锁不可能不可破解；能反编译并重编内核的人仍可移除校验。

构建所需补丁、Droidspaces、NoMount、压缩资源及辅助文件从本仓库检出。LLVM/Rust 工具链、KernelSU 组件等大型上游依赖仍由 CI 从其各自官方或固定发布地址获取。

同一仓库现在提供以下独立构建入口：

- `fastbuild_6.12.23_oneplus_15_hmbird_gold.yml` / `fastbuild_6.12.23_oneplus_15_hmbird_purple.yml`：一加 15 金标、紫标风驰构建。
- `fastbuild_6.12.38_oneplus_15t_hmbird_gold.yml` / `fastbuild_6.12.38_oneplus_15t_hmbird_purple.yml`：一加 15T 金标、紫标风驰构建。源码使用 `zaominn/android_kernel_common_oneplus_sm8850` 的 `oneplus/sm8850_b_16.0_oneplus_15t` 分支；TCP Brutal、ADIOS、Re-Kernel 源码随树提供，但仅由各自开关启用。版本号为 `android16-5-gbe6292a1543d-ab14525421-4k`，构建时间默认为 `Mon Dec 1 03:28:37 UTC 2025`，工具链为 Clang `r547379` / Rust 1.82。
- `fastbuild_6.12.38_oneplus_ace6t_hmbird_gold.yml` / `fastbuild_6.12.38_oneplus_ace6t_hmbird_purple.yml`：Ace6T 金标、紫标风驰构建，源码使用 `zaominn/android_kernel_common_oneplus_sm8845` 的 `oneplus/sm8845_b_16.0.0_ace_6t` 分支。
- `fastbuild_6.12.58_hmbird_purple.yml`：OnePlus Pad 3 Pro 紫标风驰构建；官方分支没有金标同步版本，因此不提供金标入口。
- `fastbuild_6.12.23_mtk_hmbird_gold.yml` / `fastbuild_6.12.23_mtk_hmbird_purple.yml`：OPPO Find X9 系列金标、紫标风驰构建；当前 `16.0.10.501` 使用金标。
- `fastbuild_6.12.58_mtk_hmbird_gold.yml` / `fastbuild_6.12.58_mtk_hmbird_purple.yml`：OnePlus Ace 6 Ultra（PMB110）金标、紫标风驰构建。

这些入口复用 6.12.23 已稳定使用的序列号锁、ReSukiSU 分支选择、LZ4/Zstd、LZ4KD、zarm、Unicode 修复、BBR/Brutal、Droidspaces、网络增强、ADIOS、Re-Kernel、基带保护、NoMount、AppCloak、PathMask 和刷机包命名规则，并分别保留开启/关闭选项。所有工作流默认关闭 SUSFS 和 NoMount，且两者同时开启会立即拒绝构建。15T 的序列号锁与风驰兼容固定启用；`self_config` 只属于 6.12.23 的一加 15 入口，机器人不会向 15T 工作流提交该输入。

Find X9、Ace 6 Ultra、Pad 3 Pro 和 Ace6T 的自定义功能与高通入口保持同一套内核补丁和模块链。风驰外部模块按平台分别使用 MTK/QCOM Makefile，其余功能不依赖高通专有接口。

15T 的 6.12.38 构建直接使用已验证可启动的 NMS OP15T common 基线及其 Clang r547379 / Rust 1.82 身份；源码分支额外提供 TCP Brutal、ADIOS、Re-Kernel，关闭相应开关时不会启用它们。首次构建建议保持默认选项，仅在确认启动后逐项开启其他功能。

### OnePlus 15T 风驰资料采集

请让持有 15T 的测试者保持原厂内核，打开支持风驰的游戏并停留在游戏前台，然后在电脑执行：

```sh
adb push tools/collect-oneplus15t-hmbird.sh /data/local/tmp/
adb shell
su
sh /data/local/tmp/collect-oneplus15t-hmbird.sh
exit
exit
adb pull /sdcard/Download/oneplus15t-hmbird-stock-*.tar.gz .
```

把生成的 `oneplus15t-hmbird-stock-*.tar.gz` 发回分析。压缩包包含序列号、内核日志、符号、BTF 和模块元数据，属于敏感设备诊断资料，不要公开上传。

## NoMount Suite 与 PathMask

选择 `nomount_enable` 后，CI 同时发布与该内核匹配的 `NoMount-Suite-v1.7.7.zip`。模块源码、WebUI、AppCloak 后端和二进制均保存在本仓库，不安装额外的管理应用，也不依赖外部应用隐藏项目。SUSFS 与 NoMount 必须二选一，工作流会在两者同时勾选时立即拒绝构建。

- 2026-09-20 核对 [`Bouteillepleine/NoMount-Suite`](https://github.com/Bouteillepleine/NoMount-Suite) 后，上游已更新到 `61023e9`（Suite v1.3.184 / Prism engine v32）。当前内核仍是本仓库的 v14 PathHide 协议定制分支，不能把 v32 内核端和用户态直接替换进来；CI 引擎继续固定在已验证的 `36a4621`，只移植与协议无关、可以单独验证的低开销改动。
- PathHide 只接受绝对路径，使用 RCU 不可变快照、inode 身份和 Bloom 快速拒绝；规则为空时静态分支直接旁路。删除了旧版每次读取 maps 都拿锁并做任意子串匹配的行为。手动 `+` 规则仍按原来的 global/deny 语义全局生效；`&` 规则是 AppCloak 可选补充，只在 `@uid:` 白名单中的调用方 UID 下生效。
- 从正确上游回移 `286c2ac`：合成目录正确响应 `SEEK_DATA/SEEK_HOLE`，关闭普通应用无需 root 即可识别该目录的两次 `lseek` 特征；仅在显式 seek 时执行，不增加日常常驻开销。
- 路径遮罩默认使用 `global` 作用域，对全系统读取统一返回隐藏结果；它与 NoMount 的按 UID 注入屏蔽名单相互独立。写操作保留文件系统原生行为，避免用统一错误码形成额外指纹。
- PathMask 热路径使用双哈希 2-Kbit inode 过滤器，避免隐藏规则较多时 64-bit Bloom 饱和、导致普通 `inode_permission/stat/readdir` 进入线性规则扫描；未启用规则时仍由 static key 直接跳过。
- 包列表变化使用 `inotifyd` 事件同步；极简环境缺少 `inotifyd` 时完成一次启动同步后退出，不再保留每五分钟唤醒一次的常驻轮询进程。
- 内核直接覆盖 inode 权限、stat、getdents、proc maps/fd，不加载常驻 syscall kprobe。开机完成后一次性匹配 `/dev/*/scene_mode_category` 并隐藏匹配项的父目录，同时加入 `/dev/cpuset/scene-daemon`；这一条父目录规则同时覆盖 Scene 8 的固定 `/dev/scene` 和 Scene 9.3 及以上的随机目录。它不依赖 Scene 包名、WebUI、挂载表、目录事件或定时轮询，也不保留常驻检测进程。
- 应用隐藏会缓存识别 Xposed 模块并读取 HMA 黑名单，默认勾选为隐藏目标；扫描只处理新增、变更和卸载的包，并发限制在最多 4 个 APK，避免 WebUI 刷新造成 CPU 峰值。PathMask 只保存用户手动输入的完整文件路径和 Scene 自动发现的 debugfs 路径。
- WebUI 的“隐藏 APK 路径痕迹”默认关闭。开启后，模块用 `pm list packages -f -U` 把 `hidden_apps.conf` 映射为应用目录路径规则，把 `scope_apps.conf` 映射为调用方 UID 规则，并全量重建内核补充规则。`packages.list` 变化时由 inotify 事件触发同步；卸载、重装或 UID 复用后的旧规则会被清除，不会残留到新包。该功能只补充 AppCloak，不改变手动 PathMask。
- NoMount 引擎在 CI 中从固定上游提交打上 `upstream-module-id-validation.patch` 和 `upstream-my-hookless-default.patch` 后重新编译。核心扫描会要求模块目录名与 `module.prop` 的 `id=` 完全一致，并对启用模块的重复 ID 做确定性拒绝；诊断信息把缺少 `my_hookless` 明确标为 bind 兼容回退，不再显示与默认配置冲突的试验模式和开机循环旧提示。
- 挂载兼容性分两类处理：目录名/声明 ID 不一致或重复的模块会在核心扫描阶段被明确跳过并输出原因；第三方模块自己创建的 bind mount 会先在 zygote 前、再在开机完成后由 `nomount absorb` 转成无挂载注入。安装时默认创建 `my_hookless` 标记，让 `my_product`、`my_company`、`my_region` 等 `my_*` 分区直接使用 VFS 注入，不再保留这些分区的 bind mount；删除 `/data/adb/nomount/my_hookless` 后重启可恢复 bind 兼容模式。
- 对照 Hybrid Mount 的分区规划后，`my_*` 与 `product`、`vendor` 一样按独立受管分区处理，不把 `system/my_*` 误当成普通 system 子目录。Hybrid Mount 会按模块和路径在 VFS、OverlayFS、Magic Mount 间选择；本项目保持单一 NoMount VFS 注入路径，避免为了兼容这些分区重新产生真实挂载。
- KernelSU/APatch 的 `post-mount.sh` 会在所有模块的 `post-fs-data.sh` 之后、zygote 之前运行一次 `absorb --early`，先接管启动阶段产生的可安全转换挂载；开机完成后再执行一次普通吸收处理晚创建挂载。两次完整结果写入 `/data/adb/nomount/absorb.log`，保留具体目标、来源和拒绝原因。

v1.7.7 的 WebUI 会读取设备应用并显示应用名和包名。“隐藏目标”和“生效应用”是两个独立卡片，列表可单独收起，默认只显示用户应用，各自可开启“显示系统应用”；隐藏目标中勾选即隐藏，生效应用中只有勾选的调用应用看不到隐藏目标。检测到的 Xposed 模块及 HMA 黑名单默认勾选，用户取消后会保存排除选择。PathMask 固定对全系统生效，只保存并完整显示文件绝对路径（唯一自动添加项是 Scene debugfs），手动规则可以直接删除。

AppCloak 的隐藏组内应用仍可以看到自己和所有其他应用；系统 UID 不过滤，未勾选的调用应用也不过滤。策略文件通过 inotify 事件即时更新，仅以 5 分钟低频检查兜底；列表未变化时不读取文件，调用方策略缓存最长 5 分钟，策略变更时立即失效。

## 刷入与恢复

刷入前必须保存当前系统对应的原厂 `boot.img`，确认可以进入 bootloader，并确认活动槽位。推荐使用支持 AnyKernel3 的内核刷写器；也可以解包取得 Image 后按自己的流程重打包 boot。

出现无法开机、系统升级后不兼容或序列号填错时，进入 bootloader/recovery，同时回刷与当前固件完全对应的原厂 `boot` 和 `init_boot`。不要拿其他版本、其他地区或其他机型的镜像恢复。

## 开机后验证

先在未打开游戏时执行，再打开支持风驰的游戏重复执行：

```sh
adb shell
su
dmesg | grep -E "device serial lock|hmbird_dfx|hmbird_II|sched_ext|rust_binder"
cat /sys/kernel/sched_ext/state
cat /sys/kernel/sched_ext/root/ops 2>/dev/null
cat /sys/kernel/sched_ext/nr_rejected
cat /proc/sys/hmbird/common/hmbird_manager_register
cat /proc/sys/hmbird_II/frame_per_sec
cat /proc/sys/hmbird_II/prefer_cpu
cat /proc/sys/hmbird_II/prefer_idle
cat /proc/sys/hmbird_II/prefer_preempt
```

正确设备应出现 `device serial lock: verified`。游戏前风驰通常为 `disabled`；游戏启动后应为 `enabled`、ops 为 `hmbird_II`、`nr_rejected=0`，并出现针对游戏进程的线程规则。
