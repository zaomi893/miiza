# NoMount / PathMask synchronization notes

Primary NoMount upstream:

- Repository: `Bouteillepleine/NoMount-Suite`
- Engine build revision: `36a462132102e49ed868c88cceb390aadd39f3d5`
- Latest reviewed revision: `61023e960eb1db1ee6f582ab2e44f1c176b6722a`
- Latest reviewed state: Suite `v1.3.184`, Prism engine `v32`
- License: GPL-3.0

`maxsteeel/nomount` is the historical project from which NoMount Suite was
derived; it is not the upstream used for this integration. The previous note
incorrectly named it as the current upstream.

Other reviewed sources:

- LKM-PathMask: `Andrea-lyz/LKM-PathMask@259e7bab9a416589605bfd0840df2136a173259a` (`2.8.0`; WebUI and Android 17/6.18 build updates only).
- Original local module baseline: user-supplied `NoMount-Module-v1.3.0.zip`, SHA-256 `2e60374091ae8d8f8b013fb61a851d94a30a0d890c8c9e0e0c70d8bb37e8fea3`.

The current local kernel half is a v14 PathHide protocol derivative with the
PathMask fast path integrated directly. Upstream v32 is not relabelled as
already synchronized: it changes both the engine and userspace and must be
ported as a pair, followed by a real OP15 boot/detection test. Low-risk fixes
may be backported independently, but the version shown by the kernel remains
truthful until that port is completed.

Backported independently from the primary upstream:

- `286c2ac19411492823674218c945217b08382c63`: make synthesized directories
  answer `SEEK_DATA` and `SEEK_HOLE` like their backing EROFS directories. This
  closes an unprivileged two-`lseek` detection oracle without changing the
  userspace protocol or adding steady-state overhead.
- Local compatibility patch `upstream-module-id-validation.patch`: the core
  scanner requires each enabled module's directory name to equal its declared
  `module.prop` `id=` and rejects duplicate enabled IDs deterministically. The
  workflows build the arm64 engine from this patched fixed upstream revision;
  they do not silently rely on the unpatched prebuilt binary.

PathMask uses compile-time VFS call sites; the old arm64 syscall kretprobe
fallback is compiled out because it duplicated those checks on system-wide hot
paths. A two-hash 2-Kbit inode filter keeps ordinary permission/stat/readdir
traffic out of the linear rule matcher even with a large AppCloak list.
AppCloak remains a small independent package-visibility component maintained
in this repository.
