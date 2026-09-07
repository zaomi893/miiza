# OnePlus 15 HMBIRD 自定义 GKI

为一加 15（SM8850，`infiniti`）构建可保留 ColorOS 风驰调速器（HMBIRD II）的 6.12.23 自定义 GKI，默认集成 ReSukiSU。

## 已验证能力

- 使用能在一加 15 启动的 `6.12.23-android16-5-gb2a876903b49-ab14541642-4k` 构建链。
- 继续加载原厂 `vendor_dlkm` 中的 `oplus_bsp_sched_ext.ko`。
- 为原厂风驰模块替换与本次 GKI 精确匹配的 BTF 元数据，并隐藏其他不兼容的 vendor 模块 BTF。
- 王者荣耀运行时已验证 HMBIRD II 成功加载和挂接，`sched_ext` 为 enabled，`nr_rejected=0`。
- AnyKernel3 包只替换 `boot` 中的内核 Image，不修改 `init_boot`、`vendor_boot` 或 `vendor_dlkm`。

## 构建

在 GitHub Actions 中手动运行 `6.12.23 欧加真OKI内核快速构建`，必须填写 `device_serial`。

序列号只允许 6–64 位字母、数字、点、下划线、冒号和连字符。工作流会把它直接写入内核 Image；构建日志和刷机包注释不会显示明文序列号。

## 序列号锁行为

- AnyKernel 刷入阶段不校验序列号，因此包可以正常刷入。
- 内核启动时从 bootconfig 的 `androidboot.serialno` 读取设备序列号。
- 匹配时正常启动和运行。
- 不匹配或字段缺失时仍会进入系统，但内核在启动约 180 秒后执行紧急重启；之后会重复此行为。
- 这是明文绑定，不是密码学授权：能取得内核镜像或源码的人可以找出或修改绑定值。

刷入前务必保留原厂 `boot.img`，并确保可进入 bootloader。若填错序列号导致循环重启，应在 bootloader/recovery 中回刷原厂 boot 或另一个正确绑定的内核。

## 开机后验证

```sh
su -c 'dmesg | grep -E "device serial lock|hmbird|sched_ext|oplus_bsp_sched_ext"'
cat /sys/kernel/sched_ext/state 2>/dev/null
cat /sys/kernel/sched_ext/root/ops 2>/dev/null
```

正确设备应出现 `device serial lock: verified`。打开支持风驰的游戏后，HMBIRD II 应成功挂接且日志中不应出现 `Unknown symbol`、CRC 或 BTF 不兼容错误。
