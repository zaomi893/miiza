# OnePlus 15T stock HMBIRD reference

Verified from `oneplus15t-hmbird-stock-20260908-232000.tar.gz`; the archive's
57-file SHA-256 manifest passed locally. Large stock images, modules, logs and
BTF blobs are intentionally not committed.

- Device/build: `PLZ110` / `PLZ110_16.0.5.701(CN01)`
- Stock GKI: `6.12.38-android16-5-gbe6292a1543d-ab14525421-4k`
- Stock HMBIRD module vermagic:
  `6.12.38-android16-5-o-g9f5d953c5fd6-4k SMP preempt mod_unload modversions aarch64`
- `oplus_bsp_sched_ext.ko` SHA-256:
  `6daf7ad2c7ca7e193483062f75924addd7090721f4f96b353439a4324736cffe`
- `vmlinux.btf` SHA-256:
  `71281baceb06229ac244b56c8a8563febb2540ea049fd3bcaec03a1d05e43913`
- `oplus_bsp_sched_ext.btf` SHA-256:
  `fe507294ae3d84b47b739c95afd1209f62301628fa3f35c71c5c8ba7ab95149c`

The stock capture proves the scheduler was live (`root/ops=hmbird_II`,
`state=enabled`, `switch_all=1`, zero rejected registrations), the manager
heartbeat was running, and game-specific `prefer_cpu`, `prefer_cluster`,
`prefer_idle` and `prefer_preempt` policy had been delivered for
`com.tencent.tmgp.sgame`. A custom build is not considered device-validated
until these same runtime signals pass on the 15T after a real flash.
