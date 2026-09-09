# NoMount / PathMask synchronization notes

Primary NoMount upstream:

- Repository: `Bouteillepleine/NoMount-Suite`
- Reviewed revision: `36a462132102e49ed868c88cceb390aadd39f3d5`
- Upstream state at that revision: Suite `v1.3.176`, Prism engine `v32`
- License: GPL-3.0

`maxsteeel/nomount` is the historical project from which NoMount Suite was
derived; it is not the upstream used for this integration. The previous note
incorrectly named it as the current upstream.

Other reviewed sources:

- LKM-PathMask: `Andrea-lyz/LKM-PathMask@98274c85ba41442c35b05ed316b16308551240f9` (`2.7.2`).
- Original local module baseline: user-supplied `NoMount-Module-v1.3.0.zip`, SHA-256 `2e60374091ae8d8f8b013fb61a851d94a30a0d890c8c9e0e0c70d8bb37e8fea3`.

The current local kernel half is a device-tested Prism v13 derivative with the
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

PathMask uses compile-time VFS call sites plus the six arm64 path-metadata
fallback probes and `getdents64` filtering used by LKM-PathMask 2.7.2. The
probes exist only while at least one PathMask rule is active, and deliberately
omit legacy `faccessat` to avoid its measurable timing cost. AppCloak remains
a small independent package-visibility component maintained in this repository.
