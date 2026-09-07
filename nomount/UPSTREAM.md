# NoMount / PathMask synchronization notes

- NoMount reviewed revision: `maxsteeel/nomount@2d3863b036d69fd587585ee0cdde2560d983beb8` (2026-09-04).
- LKM-PathMask reviewed revision: `Andrea-lyz/LKM-PathMask@98274c85ba41442c35b05ed316b16308551240f9` (`2.7.2`).
- Local module baseline: user-supplied `NoMount-Module-v1.3.0.zip`, SHA-256 `2e60374091ae8d8f8b013fb61a851d94a30a0d890c8c9e0e0c70d8bb37e8fea3`.

The upstream NoMount v2 control transport is intentionally not copied: it is a
breaking userspace/kernel protocol change and would invalidate the already
deployed Suite client.  The low-risk directory-iteration UID caching is ported
instead.  PathMask's behavior is implemented through compile-time VFS call
sites and the existing NoMount UID set, avoiding its optional syscall kprobes
and their permanent open/stat/access overhead.
