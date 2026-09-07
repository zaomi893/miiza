# OnePlus 15 HMBIRD 自定义 GKI

为一加 15（SM8850，`infiniti`）构建可保留 ColorOS 风驰调速器（HMBIRD II）的 6.12.23 自定义 GKI，默认集成 ReSukiSU。

## 已验证能力

- 使用能在一加 15 启动的 `6.12.23-android16-5-gb2a876903b49-ab14541642-4k` 构建链。
- 继续加载原厂 `vendor_dlkm` 中的 `oplus_bsp_sched_ext.ko`。
- 只为已核对指纹的原厂风驰模块替换与本次 GKI 精确匹配的 BTF 元数据。
- 只对国行固件中 103 个已确认不兼容的旧式 split-BTF 模块隐藏错误 BTF；不再按“所有缺少 `.BTF.base` 的模块”宽泛处理。
- 王者荣耀运行时已验证 HMBIRD II 成功加载和挂接，`sched_ext` 为 enabled，`nr_rejected=0`。
- AnyKernel3 包只替换 `boot` 中的内核 Image，不修改 `init_boot`、`vendor_boot` 或 `vendor_dlkm`。

## 构建

在 GitHub Actions 中手动运行 `6.12.23 欧加真OKI内核快速构建`，必须填写 `device_serial`。

序列号只允许 6–64 位字母、数字、点、下划线、冒号和连字符。每次构建会生成独立的 32 字节随机盐，并把 `SHA-256(随机盐 || 序列号)` 写入内核 Image，Image 中不保存明文序列号。按照本仓库发布要求，AnyKernel3 包注释和 GitHub Release 日志会显示本次输入的绑定序列号。

构建所需的补丁、Droidspaces、NoMount、压缩工具及辅助文件均从当前仓库检出，不再从旧的 `oplus_sm8850` 仓库下载。

## 序列号锁行为

- AnyKernel 刷入阶段不校验序列号，因此包可以正常刷入。
- 内核启动时从 bootconfig 的 `androidboot.serialno` 读取设备序列号。
- 校验采用每次构建独立随机盐的 SHA-256 摘要，并使用常量时间比较；风驰 BTF 兼容入口也要求序列号已验证。
- 匹配时正常启动和运行。
- 不匹配或字段缺失时仍会进入系统，但内核在启动约 180 秒后执行紧急重启；之后会重复此行为。
- 这比在 Image 中保存明文序列号更难直接搜索和篡改，但仍属于客户端软件锁，不可能做到不可破解；有能力反编译并重编内核的人仍可移除校验。Release 日志会按要求公开绑定序列号，因此随机盐与摘要主要用于防止直接二进制字符串替换，而不是隐藏序列号本身。

## 16.0.9.400 同步边界

HMBIRD 模块源码在构建时固定使用一加 15 的官方 `oneplus/sm8850_b_16.0.0_oneplus_15` 分支。16.0.9.400 的官方设备源码更新主要位于 SoC、厂商模块和设备树仓库，并包含 OOS/CPH2747 专用改动；这些内容不能作为 common GKI 补丁整体合入国行底座。当前仓库继续以实机验证能启动的 6.12.23 common 源码为基线，只消费该官方分支中与风驰模块构建直接相关的国行通用源码，排除 OOS system_dlkm 签名、CPH 设备配置和非国行刷机逻辑。

刷入前务必保留原厂 `boot.img`，并确保可进入 bootloader。若填错序列号导致循环重启，应在 bootloader/recovery 中回刷原厂 boot 或另一个正确绑定的内核。

## 开机后验证

```sh
su -c 'dmesg | grep -E "device serial lock|hmbird|sched_ext|oplus_bsp_sched_ext"'
cat /sys/kernel/sched_ext/state 2>/dev/null
cat /sys/kernel/sched_ext/root/ops 2>/dev/null
```

正确设备应出现 `device serial lock: verified`。打开支持风驰的游戏后，HMBIRD II 应成功挂接且日志中不应出现 `Unknown symbol`、CRC 或 BTF 不兼容错误。
