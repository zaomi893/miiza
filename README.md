# OnePlus 15（PLK110）HMBIRD II 自定义 GKI

本仓库在一加 15 已验证可启动的 Android 16 / Linux 6.12.23 GKI 构建链上，集成 ReSukiSU，并保留 ColorOS 风驰调速器（HMBIRD II）。目标固件为国行 `PLK110_16.0.9.400(CN01)`；不要用于 CPH2747 等非国行机型。

## 当前状态

- 内核版本：`6.12.23-android16-5-gb2a876903b49-ab14541642-4k`
- 实机：一加 15 `PLK110`，活动槽位 `boot_a`
- 系统：`PLK110_16.0.9.400(CN01)`
- Root：ReSukiSU，可正常取得 root shell
- 风驰：支持原厂 `oplus_bsp_sched_ext.ko`，游戏启动后由 `hmbird_II` 接管
- 安装包：AnyKernel3 只替换 boot 中的 GKI Image，不修改 `init_boot`、`vendor_boot` 或 `vendor_dlkm`

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

## 16.0.9.400 源码位置

同步入口在 [`.github/workflows/build.yml`](.github/workflows/build.yml)：

- 可启动的 common GKI 底座仍取自本仓库配置的 `6.12.23` 源码分支，避免换成当前无法在该机启动的官方 common 版本。
- 风驰模块源码固定到 OnePlus 官方 modules/device-tree 仓库提交 [`5ab2a689ff87d7d28c511f1762cf41c1b90d965a`](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8850/commit/5ab2a689ff87d7d28c511f1762cf41c1b90d965a)。CI 只稀疏检出 `vendor/oplus/kernel/cpu`，不会合入其中的 CPH/OOS 设备配置和非国行刷机逻辑。
- 上述同步、仓库内资源自托管及序列号锁首次汇总在本仓库提交 [`7bf19d7`](https://github.com/cvhhji/oneplus_sm8850_hmbird/commit/7bf19d7a30844120162045090b55f8d7202c8864)。官方上游提交本身同时包含多地区内容，因此这里准确的边界是“仅消费风驰 CPU 模块目录”，不是把整个提交宣称为 CN-only。

## 风驰兼容方式

手机继续加载原厂 `vendor_dlkm` 中的模块代码，本仓库不会用自编译 `.ko` 覆盖原厂模块。构建流程会使用同一次 GKI 编译的 BTF ID 空间编译官方风驰源码，只提取生成模块的 `.BTF` 和 `.BTF_ids` 元数据，再写入 Image 中预留的固定槽位；模块装载时仅对已核对身份的原厂风驰模块使用这份匹配元数据。

另有 103 个国行固件模块携带与自定义 GKI 不兼容的旧式 split-BTF。内核只按仓库内固定名单忽略这些模块的错误 BTF，而不改模块代码、符号 CRC 或 KMI，也不会宽泛屏蔽所有模块的 BTF 检查。风险是名单与其他固件版本不一定一致，因此本仓库只声明支持 `PLK110_16.0.9.400(CN01)`；系统升级后必须重新验证。

## 原厂模块兼容日志

- `rust_binder: Unknown symbol` 是原厂模块与自定义 GKI 的 Rust `core/kernel/bindings` crate 哈希不同导致的。实机逐项核对的 76 个引用在本 GKI 中都有同名、同签名导出；兼容桥只在设备序列号已验证、模块名为 `rust_binder` 且 `scmversion=gb2a876903b49` 时替换 3 个精确 crate 哈希，并继续执行内核原有的 modversion CRC 检查。构建也会确认全部映射目标存在，避免静默放宽模块解析。实机已确认模块成功加载且 `Unknown symbol=0`。
- `hb_bpf_cpuperf_set -> kernel/sched/sched.h:1705` WARN 在原厂 boot 和自定义 boot 上均可复现，且两者风驰均正常接管、`nr_rejected=0`。这是原厂风驰路径的行为，不通过隐藏日志或更改调度逻辑来冒险“修复”。

## 构建与设备序列号锁

在 GitHub Actions 手动运行 `6.12.23 欧加真OKI内核快速构建`，必须填写 `device_serial`。允许 6–64 位字母、数字、点、下划线、冒号和连字符。

每次构建生成独立的 32 字节随机盐，并将 `SHA-256(随机盐 || 序列号)` 写入 Image，不保存明文序列号。刷入阶段不校验；内核启动时从 bootconfig 读取设备序列号并用常量时间比较。匹配时正常启动，不匹配或缺失时约 180 秒后紧急重启。风驰 BTF 兼容入口也要求序列号已经验证。

GitHub Release 日志和刷机包注释会按要求显示本次输入的绑定序列号。该机制能阻止误刷并提高直接二进制修改门槛，但客户端锁不可能不可破解；能反编译并重编内核的人仍可移除校验。

构建所需补丁、Droidspaces、NoMount、压缩资源及辅助文件从本仓库检出。LLVM/Rust 工具链、KernelSU 组件等大型上游依赖仍由 CI 从其各自官方或固定发布地址获取。

## NoMount Suite 与 PathMask

选择 `nomount_enable` 后，CI 同时发布与该内核匹配的 `NoMount-Suite-v1.5.0.zip`。模块源码、WebUI 和二进制均保存在本仓库的 `nomount/module`，不会在构建时从未知地址替换。

- 同步 NoMount 上游截至 `2d3863b` 的目录遍历 UID 缓存思路，同时保留本仓库已经过设备验证的 v13 协议和防检测修复，不直接替换成不兼容的上游 v2 用户态协议。
- PathHide 只接受绝对路径，使用 RCU 不可变快照、inode 身份和 Bloom 快速拒绝；规则为空时静态分支直接旁路。删除了旧版每次读取 maps 都拿锁并做任意子串匹配的行为。
- 路径隐藏默认使用 `deny` 作用域：只有 WebUI“按 UID 隐藏”列表内的应用会得到 `ENOENT`/隐藏目录项。写操作保留文件系统原生行为，避免用统一错误码形成额外指纹。
- 借鉴 LKM-PathMask `2.7.2` 的目标身份与 Scene 发现设计，内核直接覆盖 inode 权限、stat、getdents、proc maps/fd，不加载常驻 syscall kprobe。官方 Scene（`com.omarea.vtools`）存在时，模块最多观察十分钟，只接受 `/dev` 下、SELinux 标签为 `u:object_r:debugfs:s0` 的 debugfs 挂载；发现或超时后进程退出。
- Xposed 扫描保存 APK 的真实绝对路径。HMA 黑名单是“需要隐藏环境的应用”，现在会进入 UID 作用域，不再被错误当成路径包名；这是旧 PathHide 可能让目标应用闪退的主要修复。

升级 v1.5.0 时，旧 `pathhide.conf` 中的包名/子字符串会被自动丢弃，重新扫描后写入真实 APK 路径。WebUI 的“PathMask 应用隐藏”会自动识别 Xposed 模块和 Scene debugfs，并通过“PathMask 目标应用”选择隐藏范围。

## 刷入与恢复

刷入前必须保存当前系统对应的原厂 `boot.img`，确认可以进入 bootloader，并确认活动槽位。推荐使用支持 AnyKernel3 的内核刷写器；也可以解包取得 Image 后按自己的流程重打包 boot。

出现无法开机、系统升级后不兼容或序列号填错时，进入 bootloader/recovery 回刷与当前固件完全对应的原厂 boot。不要拿其他版本、其他地区或其他机型的 boot 恢复。

## 开机后验证

先在未打开游戏时执行，再打开支持风驰的游戏重复执行：

```sh
su -c 'dmesg | grep -E "device serial lock|hmbird_dfx|hmbird_II|sched_ext|rust_binder"'
su -c 'cat /sys/kernel/sched_ext/state'
su -c 'cat /sys/kernel/sched_ext/root/ops 2>/dev/null'
su -c 'cat /sys/kernel/sched_ext/nr_rejected'
su -c 'cat /proc/sys/hmbird/common/hmbird_manager_register'
su -c 'cat /proc/sys/hmbird_II/frame_per_sec'
su -c 'cat /proc/sys/hmbird_II/prefer_cpu'
su -c 'cat /proc/sys/hmbird_II/prefer_idle'
su -c 'cat /proc/sys/hmbird_II/prefer_preempt'
```

正确设备应出现 `device serial lock: verified`。游戏前风驰通常为 `disabled`；游戏启动后应为 `enabled`、ops 为 `hmbird_II`、`nr_rejected=0`，并出现针对游戏进程的线程规则。
