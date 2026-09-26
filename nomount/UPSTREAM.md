# NoMount / PathMask synchronization notes

Primary NoMount upstream:

- Repository: `Bouteillepleine/NoMount-Suite`
- Engine and userspace build revision: `2490ebd969eab55412bf61c7dabbef9b01affc8f` (`v1.3.186`)
- Latest reviewed revision: `d20044bbe030520736d84c7d39a4d661b1ca974f`
- Latest reviewed state: Suite `v1.3.186`, Prism engine `v33` (2026-09-25)
- License: GPL-3.0

`maxsteeel/nomount` is the historical project from which NoMount Suite was
derived; it is not the upstream used for this integration. The previous note
incorrectly named it as the current upstream.

Other reviewed sources:

- LKM-PathMask: `Andrea-lyz/LKM-PathMask@259e7bab9a416589605bfd0840df2136a173259a` (`2.8.0`; WebUI and Android 17/6.18 build updates only).
- Original local module baseline: user-supplied `NoMount-Module-v1.3.0.zip`, SHA-256 `2e60374091ae8d8f8b013fb61a851d94a30a0d890c8c9e0e0c70d8bb37e8fea3`.

Actions builds the kernel engine and Rust userspace from the same upstream v33
revision, then applies local extensions as the combined NoMount protocol v35.
Local-only PathHide, procfs boot-state spoofing and uname override remain in
`nomount_local.inc`. The ten build workflows copy that local extension beside
the upstream engine, apply the 6.12 VFS integration patch, and build a matching
`nm` client from the pinned upstream source plus the local compatibility patch.
This source migration still requires a kernel build and real OP15 boot/detection
test before it can be treated as a hardware-validated release.

The v35 contract retains the v33 raw-netlink protocol number, message types,
existing attribute IDs, rule layout, EROFS/isolated/ghost knobs, and Rust Suite
behavior. It restores the old local boot-identity knob IDs 0-3 (`r`, `v`, `c`,
`b`) and the PathHide `/proc/pathhide` command interface. GET_VERSION now
returns version `35` plus attribute 7, a capability bitmap: bit 0 = v33 engine,
bit 1 = boot-identity knobs, bit 2 = PathHide. The matching `nm caps` command
reports both values, and `nm version` remains an alias for `nm v`. PathHide's
legacy `+`, `&`, `-`, `@uid`, `@appcloak-clear`, and scope commands stay valid;
no existing `/proc/pathhide` configuration needs conversion. The old `v14`
identifier is no longer advertised as a separate current protocol version.
The optional upstream Ghost backend is not present in these kernel sources.
Its unresolved weak function references generated forbidden arm64 GOT/PLT
sections during the full kernel link, so Ghost calls are compiled only when a
matching implementation is supplied with `CONFIG_NOMOUNT_GHOST_BACKEND`.
Without that backend the engine keeps the protocol commands but reports Ghost
control as unsupported, matching the previous runtime behavior when the weak
symbols were absent.

The upstream tag's checked-in `module/module.prop` still says `v1.3.181`, so
workflow version checks use `Cargo.toml` (`1.3.186`) and pin the exact tag commit.

Local adaptations retained alongside the upstream v33 engine:

- `fdff0bc5b52046221ba2b02a4d05d85b98664bd3`: count module bind mounts
  by an exact `/data/adb/modules/<id>` path in `mountinfo`, so dots and other
  regex characters in module IDs do not inflate the WebUI badge.
- The EROFS `SEEK_DATA` / `SEEK_HOLE` fix from
  `286c2ac19411492823674218c945217b08382c63` is part of upstream v33 itself.
- Local compatibility patch `upstream-module-id-validation-v186.patch`: the core
  scanner requires each enabled module's directory name to equal its declared
  `module.prop` `id=` and rejects duplicate enabled IDs deterministically. The
  workflows build the arm64 engine from this patched fixed upstream revision;
  they do not silently rely on the unpatched prebuilt binary.
- Local behavior patch `upstream-my-hookless-default-v186.patch`: diagnostics describe
  `my_*` bind handling as an explicit compatibility fallback and direct the user
  to restore the default `my_hookless` marker. Obsolete trial and boot-loop text
  is not compiled into the released engine.

LKM-PathMask resolves configured paths to `(device, inode)` identities, then
filters inode permission, metadata and directory-listing paths. It also has
arm64 syscall-entry fallbacks because ThinLTO can inline VFS functions and skip
out-of-line hooks; its default fallback set deliberately omits `faccessat` due
measurable timing overhead. Its global scope hides paths from root too; its
UID allow-list mode is a static UID exception list, not a KernelSU root-grant
check.

NoMount keeps its lower-overhead source-integrated VFS checks and two-hash
2-Kbit inode filter. The syscall fallbacks are now registered only while a
rule needs text matching (a directory prefix, unresolved target, or inode 0
such as some FUSE files), and the old getdents kretprobe is removed because
the kernel-source readdir hook already handles normal inode identities. A
source hook in `vfs_getattr_nosec()` already checks metadata paths, so the
redundant `newfstatat` and `statx` syscall probes are omitted. Only four
fallback probes remain for path operations not covered by that metadata hook:
`faccessat2`, `readlinkat`, `openat`, and `openat2`. A
matching path is exempted for root and KernelSU-authorized UIDs only after a
rule actually matches, avoiding the authorization lookup on unrelated file
traffic. Text matching now discovers the four common shared-storage roots and
uses only roots proven to resolve to the same `(device, inode)`; paths below
those roots match by their saved relative suffix regardless of which alias an
app uses. Suffix offsets and lengths are derived from the bounded stored rule
string, with explicit range checks before comparing, so long paths cannot
read beyond the saved target. FUSE entries with inode 0 are still omitted from
inode-based directory-list filtering; the syscall fallback covers direct
absolute-path checks, not `getdents` names. AppCloak remains a small independent
package-visibility component maintained in this repository.
