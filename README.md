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

一加 15 与一加 15T 分别提供金标、紫标两套风驰源码入口。四条工作流都只在 `vendor/oplus/kernel/cpu` 目录消费 OnePlusOSS 官方模块源码，并用同一次 GKI 编译提取匹配的 `.BTF` / `.BTF_ids`：

| 机型 | 版本 | 官方同步版本 | 工作流 |
| --- | --- | --- | --- |
| 一加 15 | 金标 | `PLK110_16.0.9.400(CN01)`，[`5ab2a689`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850/commit/5ab2a689ff87d7d28c511f1762cf41c1b90d965a) | `fastbuild_6.12.23_oneplus_15_hmbird_gold.yml` |
| 一加 15 | 紫标 | `PLK110_16.0.5.701(CN01)`，[`7fb7abf`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850/commit/7fb7abf097a18c6e2ad2fb9d18876b095898e87f) | `fastbuild_6.12.23_oneplus_15_hmbird_purple.yml` |
| 一加 15T | 金标 | `PLZ110_16.0.8.300(CN01)`，[`d447f71`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850/commit/d447f713d6403f707a2910383495f4ada98cfa4d) | `fastbuild_6.12.38_oneplus_15t_hmbird_gold.yml` |
| 一加 15T | 紫标 | `PLZ110_16.0.4.603(CN01)`，[`bc8d91d`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850/commit/bc8d91d1e146be96d2e27bebe8f753f82bdebeee) | `fastbuild_6.12.38_oneplus_15t_hmbird_purple.yml` |

一加 15 的 common GKI 底座仍取自本仓库配置的 `6.12.23` 源码分支，避免换成当前无法在该机启动的官方 common 版本；一加 15T 的底座继续跟随 `oneplus/sm8850_b_16.0_oneplus_15t` 已验证启动链。金标、紫标只改变风驰模块源码提交，不改变内核底座、工具链、启动基线或序列号锁。`7fb7abf` 与 `bc8d91d` 不再是当前分支头，工作流按完整 SHA 精确获取这两个历史同步点。

## 风驰兼容方式

手机继续加载原厂 `vendor_dlkm` 中的模块代码，本仓库不会用自编译 `.ko` 覆盖原厂模块。构建流程会使用同一次 GKI 编译的 BTF ID 空间编译官方风驰源码，只提取生成模块的 `.BTF` 和 `.BTF_ids` 元数据，再写入 Image 中预留的固定槽位；模块装载时仅对已核对身份的原厂风驰模块使用这份匹配元数据。

另有 103 个国行固件模块携带与自定义 GKI 不兼容的旧式 split-BTF。内核只按仓库内固定名单忽略这些模块的错误 BTF，而不改模块代码、符号 CRC 或 KMI，也不会宽泛屏蔽所有模块的 BTF 检查。风险是名单与其他固件版本不一定一致，因此本仓库只声明支持 `PLK110_16.0.9.400(CN01)`；系统升级后必须重新验证。

## 原厂模块兼容日志

- `rust_binder: Unknown symbol` 是原厂模块与自定义 GKI 的 Rust `core/kernel/bindings` crate 哈希不同导致的。实机逐项核对的 76 个引用在本 GKI 中都有同名、同签名导出；兼容桥只在设备序列号已验证、模块名为 `rust_binder` 且 `scmversion=gb2a876903b49` 时替换 3 个精确 crate 哈希，并继续执行内核原有的 modversion CRC 检查。构建也会确认全部映射目标存在，避免静默放宽模块解析。实机已确认模块成功加载且 `Unknown symbol=0`。
- `hb_bpf_cpuperf_set -> kernel/sched/sched.h:1705` WARN 在原厂 boot 和自定义 boot 上均可复现，且两者风驰均正常接管、`nr_rejected=0`。这是原厂风驰路径的行为，不通过隐藏日志或更改调度逻辑来冒险“修复”。

## 构建与设备序列号锁

在 GitHub Actions 手动运行 `6.12.23 欧加真OKI内核快速构建`，必须填写 `device_serial`。允许 6–64 位字母、数字、点、下划线、冒号和连字符。

每次构建生成独立的 32 字节随机盐和一次性启动标记令牌，将 `SHA-256(随机盐 || 序列号)` 写入 Image，不保存明文序列号。AK3 中的 `serial_lock/` 只是刷机资源目录；其中 `build-token` 是 64 位十六进制的本次构建随机令牌，不是序列号。刷入时 AK3 不读取、创建、删除或改写 `init_boot` 标记，只创建 `/data/adb/service.d/service_log.sh` 一次性脚本，临时运行资源放在 `/data/local/tmp/serial_lock_stage`，不创建 KernelSU/Magisk 模块或 `module.prop`。启动时由内核直接校验序列号：匹配时不安排重启并向一次性脚本报告 `verified`；不匹配时由内核自行启动固定 180 秒重启。`service_log` 是唯一允许改写标记的组件：匹配且已有标记时删除标记，没有标记则完全不写 `init_boot`；不匹配时写入本次构建标记，已有旧标记也覆盖。无论结果如何，退出时都会删除自身和整个临时目录。标记成功时才启用下一次启动的早期拒绝。风驰 BTF 兼容入口仍要求序列号已经验证。

这是高风险的实验性防误刷机制。刷机环境必须能写入 `/data/adb` 和 `/data/local/tmp`，否则 AK3 会在刷 boot 前中止；`service_log` 运行时还必须能读写当前槽 `init_boot`。序列号不匹配时，内核本身保证本次启动在 180 秒后重启。只有标记成功写入并回读一致时，下一次启动才进入早期拒绝。

GitHub Release 日志和刷机包注释会按要求显示本次输入的绑定序列号。该机制能阻止误刷并提高直接二进制修改门槛，但客户端锁不可能不可破解；能反编译并重编内核的人仍可移除校验。

构建所需补丁、Droidspaces、NoMount、压缩资源及辅助文件从本仓库检出。LLVM/Rust 工具链、KernelSU 组件等大型上游依赖仍由 CI 从其各自官方或固定发布地址获取。

同一仓库现在还提供三条独立构建入口：

- `fastbuild_6.12.38_oneplus_ace6t.yml`：沿用 Ace6T 源码的 6.12.38 构建。
- `fastbuild_6.12.38_oneplus_15t.yml`：一加 15T 专用 6.12.38 快速构建。源码使用 `zaomi893/android_kernel_common_oneplus_sm8850` 的 `oneplus/sm8850_b_16.0_oneplus_15t` 分支，固定 `14ba6a5ab0...`（其父提交为已验证可启动的 `150cab866c...`）；TCP Brutal、ADIOS、Re-Kernel 源码随树提供，但仅由各自开关启用。版本号为 `android16-5-gbe6292a1543d-ab14525421-4k`，构建时间默认为 `Mon Dec 1 03:28:37 UTC 2025`，工具链为 Clang `r547379` / Rust 1.82，继续固定 `CONFIG_LTO_NONE=y`。
- `fastbuild_6.12.38_oneplus_15t_clean.yml`：一加 15T 干净可启动基线，只加入当前公开仓库的 ReSukiSU root，不加入风驰 BTF、序列号锁或其他功能；通过 uname、ARM64 Image、`CONFIG_LTO_NONE`、`CONFIG_KSU` 和 BTF 配置检查后再上传刷机包。

15T 的 6.12.38 推荐使用上述完整快速构建入口，而不是仅用于增量取样的 `op15t_serial_hmbird.yml`。该入口采用与 6.12.23 相同的显式源码、工具链、ccache、补丁、序列号锁、风驰 BTF 元数据和 AnyKernel3 流程；序列号锁与风驰兼容默认开启，其余自定义功能均保留为可选输入，默认值维持 NMS 已验证的可启动组合。这样可以在保持 15T 启动和风驰基线的前提下，按需选择 LZ4/Zstd、LZ4KD、Droidspaces、网络增强、ADIOS、Re-Kernel、基带保护、NoMount、SUSFS 和 KPM 等功能。
- `fastbuild_6.12.58.yml`：6.12.58 构建。

三者均复用 6.12.23 已稳定使用的序列号锁、ReSukiSU 分支选择、LZ4/Zstd、LZ4KD、zarm、Unicode 修复、BBR/Brutal、Droidspaces、网络增强、ADIOS、Re-Kernel、基带保护、NoMount v1.6.8、AppCloak、PathMask 和刷机包命名规则，并分别保留开启/关闭选项。所有工作流现在默认关闭 SUSFS 和 NoMount，且两者同时开启会立即拒绝构建。15T 的 6.12.38 工作流已切换到 `oneplus/sm8850_b_16.0_oneplus_15t` 分支，该分支以已验证可启动的 `150cab866c...` 为父提交并内置 TCP Brutal、ADIOS、Re-Kernel 源码；这些功能仍由独立开关控制，默认组合保持启动基线，风驰兼容与序列号锁固定启用。

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

选择 `nomount_enable` 后，CI 同时发布与该内核匹配的 `NoMount-Suite-v1.6.8.zip`。模块源码、WebUI、AppCloak 后端和二进制均保存在本仓库，不安装额外的管理应用，也不依赖外部应用隐藏项目。SUSFS 与 NoMount 必须二选一，工作流会在两者同时勾选时立即拒绝构建。

- 正确上游为 [`Bouteillepleine/NoMount-Suite`](https://github.com/Bouteillepleine/NoMount-Suite)，2026-09-09 再次拉取核对后，`origin/main` 仍为 `36a4621`（Suite v1.3.176 / Prism engine v32），与本仓库已固定的上游提交一致，因此本次没有可继续同步的新提交。当前内核仍如实标记为 v13 定制分支；v32 内核协议需要单独移植和真机验证，不会冒充“已同步”。
- PathHide 只接受绝对路径，使用 RCU 不可变快照、inode 身份和 Bloom 快速拒绝；规则为空时静态分支直接旁路。删除了旧版每次读取 maps 都拿锁并做任意子串匹配的行为。
- 从正确上游回移 `286c2ac`：合成目录正确响应 `SEEK_DATA/SEEK_HOLE`，关闭普通应用无需 root 即可识别该目录的两次 `lseek` 特征；仅在显式 seek 时执行，不增加日常常驻开销。
- 路径遮罩默认使用 `global` 作用域，对全系统读取统一返回隐藏结果；它与 NoMount 的按 UID 注入屏蔽名单相互独立。写操作保留文件系统原生行为，避免用统一错误码形成额外指纹。
- 借鉴 LKM-PathMask `2.7.2` 的目标身份与 Scene 发现设计，内核直接覆盖 inode 权限、stat、getdents、proc maps/fd，不加载常驻 syscall kprobe。官方 Scene（`com.omarea.vtools`）存在时，模块最多观察十分钟，只接受 `/dev` 下、SELinux 标签为 `u:object_r:debugfs:s0` 的 debugfs 挂载；发现或超时后进程退出。
- 应用隐藏会缓存识别 Xposed 模块并读取 HMA 黑名单，默认勾选为隐藏目标；这些包名不会加入 PathMask。PathMask 只保存用户手动输入的完整文件路径和 Scene 自动发现的 debugfs 路径。

v1.6.8 的 WebUI 会读取设备应用并显示应用名和包名。“隐藏目标”和“生效应用”是两个独立卡片，列表可单独收起，默认只显示用户应用，各自可开启“显示系统应用”；隐藏目标中勾选即隐藏，生效应用中只有勾选的调用应用看不到隐藏目标。检测到的 Xposed 模块及 HMA 黑名单默认勾选，用户取消后会保存排除选择。PathMask 固定对全系统生效，只保存并完整显示文件绝对路径（唯一自动添加项是 Scene debugfs），手动规则可以直接删除。

AppCloak 的隐藏组内应用仍可以看到自己和所有其他应用；系统 UID 不过滤，未勾选的调用应用也不过滤。策略文件最多每秒检查一次时间戳，列表未变化时不读取文件。

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
