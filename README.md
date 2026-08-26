# OnePlus SM8850 HMBIRD II Builder

一加 15（SM8850/canoe）Android 16 整套内核构建项目。同步组装官方 common、device kernel、设备树及 Oplus vendor 模块，目标是保留 `oplus_bsp_sched_ext.ko`（HMBIRD II）、`oplus_bsp_sched_assist.ko`、频率治理、CameraScene 和 DTB/DTBO。

三个源码仓库必须使用同一分支：`oneplus/sm8850_b_16.0.0_oneplus_15`。

Actions 中运行 **Build OnePlus 15 HMBIRD kernel**。工作流会先验证 HMBIRD 源码及目标，再尝试公开 Kleaf 构建。官方 `oplus_build.sh` 依赖完整 VND Android 环境，因此公开源码不能完成时会上传诊断，不会把不完整文件冒充可刷整包。
