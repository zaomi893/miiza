# OnePlus 15 stock-HMBIRD custom GKI

为一加 15（SM8850，`infiniti`）构建可保留 ColorOS 风驰调速器（HMBIRD II）的自定义 GKI。

## 已确认的官方镜像结构

- `boot.img` 内核为 `6.12.23-android16-5-gb2a876903b49-ab14541642-4k`。
- 对应公开 ACK 源码提交为 `b2a876903b495c444a94b16f50d1463ffe953957`。
- 风驰本体是官方 `vendor_dlkm` 中的 `oplus_bsp_sched_ext.ko`，不是 boot 内置调度器。
- 刷机包只替换 `boot` 中的 `Image`，不会写入 `init_boot`、`vendor_boot` 或 `vendor_dlkm`。

因此，本项目固定使用原厂 ACK 提交、从用户提供的官方 `boot.img` 提取并校验的完整内核配置、原厂版本字符串、OPlus KMI 符号表以及风驰所需的 sched_ext/BPF/BTF 配置。不能用通用 `gki_defconfig` 代替该配置；任一关键检查失败，构建会直接失败，不会产出标称“支持风驰”的刷机包。

## 构建

在 Actions 中运行 **Build OnePlus 15 stock-HMBIRD GKI**：

- `resukisu`：默认，集成 ReSukiSU。
- `none`：先构建无 root 的兼容性基线。

成功后下载 `oneplus15-stock-hmbird-*` artifact，其中包括：

- `oneplus15-stock-hmbird-*.zip`：AnyKernel3 可刷包，只更新 boot 内核。
- `Image`：原始 GKI 镜像。
- `config`、`System.map`、`compatibility.txt`：兼容性检查依据。

## 刷入前提

此构建只适用于与 `reference/stock-baseline.txt` 对应的官方固件。必须保留该固件原装的 `init_boot`、`vendor_boot` 和 `vendor_dlkm`。更新 ColorOS 后，应重新提取新版本官方 boot/vendor_dlkm 并更新源码提交与 KMI 基线，不能继续沿用旧包。

建议先刷 `KSU_TYPE=none` 的基线版本验证风驰，再刷 ReSukiSU 版本。保留官方 `boot.img`，出现不开机或模块不兼容时可立即回刷。

## 开机后验证

```sh
uname -r
cat /sys/kernel/sched_ext/state 2>/dev/null
cat /sys/kernel/sched_ext/root/ops 2>/dev/null
lsmod | grep -E 'oplus_bsp_sched_ext|sched'
dmesg | grep -iE 'hmbird|sched_ext|oplus_bsp_sched_ext|unknown symbol|disagrees about version'
```

正常情况下，`oplus_bsp_sched_ext` 已加载，日志中没有 `Unknown symbol`、版本 CRC 或 BTF 不兼容错误，ColorOS 风驰服务启动后 sched_ext 会显示启用的调度器。
