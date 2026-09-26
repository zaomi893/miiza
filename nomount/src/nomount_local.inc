/* ---- /proc/cmdline + /proc/bootconfig spoofing --------------------------------
 * androidboot.* boot state (verifiedbootstate, lock, warranty, vbmeta.digest) lives in
 * /proc/cmdline and, on GKI, /proc/bootconfig. resetprop only moves the derived
 * ro.boot.* props, leaving these procfs sources contradicting them -- a detection tell.
 * A procfs seq-file has no backing inode to vtable-hijack, so on the first write to the
 * sysfs knob we take over the proc entry itself and serve the sanitized string. This
 * happens at post-fs-data (procfs long up), and init's early parse of the real kernel
 * command line is untouched. Empty write => passthrough (the real value). */
static char *nm_fake_cmdline;
static struct proc_dir_entry *nm_cmdline_pde;
static DEFINE_MUTEX(nm_procspoof_mutex);

static int nm_cmdline_show(struct seq_file *m, void *v)
{
    mutex_lock(&nm_procspoof_mutex);
    seq_printf(m, "%s\n", nm_fake_cmdline ? nm_fake_cmdline : saved_command_line);
    mutex_unlock(&nm_procspoof_mutex);
    return 0;
}

#ifdef CONFIG_BOOT_CONFIG
static char *nm_fake_bootconfig, *nm_orig_bootconfig;
static struct proc_dir_entry *nm_bootconfig_pde;

static int nm_bootconfig_show(struct seq_file *m, void *v)
{
    mutex_lock(&nm_procspoof_mutex);
    if (nm_fake_bootconfig)      seq_puts(m, nm_fake_bootconfig);
    else if (nm_orig_bootconfig) seq_puts(m, nm_orig_bootconfig);
    mutex_unlock(&nm_procspoof_mutex);
    return 0;
}

/* Snapshot the real /proc/bootconfig once, before we replace it, so an empty write can
 * fall back to the genuine text (bootconfig is not reproducible from a global). */
static char *nm_snapshot_bootconfig(void)
{
    struct file *f;
    char *buf;
    loff_t pos = 0;
    ssize_t n;

    f = filp_open("/proc/bootconfig", O_RDONLY, 0);
    if (IS_ERR(f)) return NULL;
    buf = kmalloc(SZ_64K, GFP_KERNEL);
    if (!buf) { filp_close(f, NULL); return NULL; }
    n = kernel_read(f, buf, SZ_64K - 1, &pos);
    filp_close(f, NULL);
    if (n <= 0) { kfree(buf); return NULL; }
    buf[n] = '\0';
    return buf;
}
#endif /* CONFIG_BOOT_CONFIG */

#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 17, 0)
static int nm_cmdline_open(struct inode *i, struct file *f) { return single_open(f, nm_cmdline_show, NULL); }
static const struct file_operations nm_cmdline_fops = {
    .open = nm_cmdline_open, .read = seq_read, .llseek = seq_lseek, .release = single_release,
};
#ifdef CONFIG_BOOT_CONFIG
static int nm_bootconfig_open(struct inode *i, struct file *f) { return single_open(f, nm_bootconfig_show, NULL); }
static const struct file_operations nm_bootconfig_fops = {
    .open = nm_bootconfig_open, .read = seq_read, .llseek = seq_lseek, .release = single_release,
};
#endif
#endif /* < 4.17 */

/* trim trailing newline/CR then dup; empty => NULL (passthrough) */
static char *nm_dup_trim(const char *buf, size_t count)
{
    while (count && (buf[count - 1] == '\n' || buf[count - 1] == '\r')) count--;
    return count ? kstrndup(buf, count, GFP_KERNEL) : NULL;
}

/* proc has no rename and refuses a duplicate name, so a takeover must
 * remove-then-create. If the create then fails the entry is gone for good, and a
 * MISSING /proc/cmdline is both a louder tell and more breaking than an
 * unsanitised one -- so retry, and report instead of failing silently. */
static struct proc_dir_entry *nm_mk_cmdline_pde(void)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 17, 0)
    return proc_create_single("cmdline", 0444, NULL, nm_cmdline_show);
#else
    return proc_create("cmdline", 0444, NULL, &nm_cmdline_fops);
#endif
}

#ifdef CONFIG_BOOT_CONFIG
static struct proc_dir_entry *nm_mk_bootconfig_pde(void)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 17, 0)
    return proc_create_single("bootconfig", 0444, NULL, nm_bootconfig_show);
#else
    return proc_create("bootconfig", 0444, NULL, &nm_bootconfig_fops);
#endif
}
#endif

static int nm_set_cmdline(const char *buf, size_t c)
{
    char *nb = nm_dup_trim(buf, c);
    mutex_lock(&nm_procspoof_mutex);
    kfree(nm_fake_cmdline);
    nm_fake_cmdline = nb;
    if (!nm_cmdline_pde) {
        remove_proc_entry("cmdline", NULL);
        nm_cmdline_pde = nm_mk_cmdline_pde();
        if (!nm_cmdline_pde) nm_cmdline_pde = nm_mk_cmdline_pde();
        if (!nm_cmdline_pde) {
            kfree(nm_fake_cmdline);
            nm_fake_cmdline = NULL;
            nm_err("procspoof: /proc/cmdline takeover failed, entry lost\n");
            mutex_unlock(&nm_procspoof_mutex);
            return -EIO;
        }
    }
    mutex_unlock(&nm_procspoof_mutex);
    return 0;
}

#ifdef CONFIG_BOOT_CONFIG
static int nm_set_bootconfig(const char *buf, size_t c)
{
    char *nb = nm_dup_trim(buf, c);
    mutex_lock(&nm_procspoof_mutex);
    if (!nm_bootconfig_pde) {
        if (!nm_orig_bootconfig) nm_orig_bootconfig = nm_snapshot_bootconfig();
        /* Never take over into an empty /proc/bootconfig: if we have neither a fake
         * (empty write) nor a snapshot to passthrough, serving nothing is itself a
         * tell (stock is never empty). Leave the genuine entry in place. */
        if (!nb && !nm_orig_bootconfig) {
            mutex_unlock(&nm_procspoof_mutex);
            return 0;
        }
        kfree(nm_fake_bootconfig);
        nm_fake_bootconfig = nb;
        remove_proc_entry("bootconfig", NULL);
        nm_bootconfig_pde = nm_mk_bootconfig_pde();
        if (!nm_bootconfig_pde) nm_bootconfig_pde = nm_mk_bootconfig_pde();
        if (!nm_bootconfig_pde) {
            kfree(nm_fake_bootconfig);
            nm_fake_bootconfig = NULL;
            nm_err("procspoof: /proc/bootconfig takeover failed, entry lost\n");
            mutex_unlock(&nm_procspoof_mutex);
            return -EIO;
        }
    } else {
        kfree(nm_fake_bootconfig);
        nm_fake_bootconfig = nb;
    }
    mutex_unlock(&nm_procspoof_mutex);
    return 0;
}
#endif /* CONFIG_BOOT_CONFIG */

static int nm_uts_store(char *field, size_t fieldsz, const char *buf, size_t count)
{
    char tmp[__NEW_UTS_LEN + 1];
    size_t n = count;

    if (n && buf[n - 1] == '\n') n--;
    if (n > __NEW_UTS_LEN) return -EINVAL;
    memcpy(tmp, buf, n);
    tmp[n] = '\0';
    if (n == 0 || strcmp(tmp, "default") == 0) return 0;

    down_write(&uts_sem);
    memset(field, 0, fieldsz);
    memcpy(field, tmp, n);
    up_write(&uts_sem);
    return 0;
}

static void nm_procspoof_exit(void)
{
    struct proc_dir_entry *cpde;
#ifdef CONFIG_BOOT_CONFIG
    struct proc_dir_entry *bpde;
#endif
    /* Detach and free under the lock, but call remove_proc_entry OUTSIDE it:
     * remove_proc_entry blocks until in-flight readers finish, and those readers
     * (nm_cmdline_show/nm_bootconfig_show) take nm_procspoof_mutex themselves --
     * holding it across the removal would be an ABBA deadlock. Once the pointer is
     * NULLed under the lock, show falls back to saved_command_line (never freed). */
    mutex_lock(&nm_procspoof_mutex);
    cpde = nm_cmdline_pde; nm_cmdline_pde = NULL;
    kfree(nm_fake_cmdline); nm_fake_cmdline = NULL;
#ifdef CONFIG_BOOT_CONFIG
    bpde = nm_bootconfig_pde; nm_bootconfig_pde = NULL;
    kfree(nm_fake_bootconfig); nm_fake_bootconfig = NULL;
    kfree(nm_orig_bootconfig); nm_orig_bootconfig = NULL;
#endif
    mutex_unlock(&nm_procspoof_mutex);

    if (cpde) remove_proc_entry("cmdline", NULL);
#ifdef CONFIG_BOOT_CONFIG
    if (bpde) remove_proc_entry("bootconfig", NULL);
#endif

}

/* =====================================================================
 * PathHide (Cloak maps/fd)
 * =====================================================================
 * Hides user-selected full file paths from
 * /proc/<pid>/maps and /proc/<pid>/fd, controlled through the
 * /proc/pathhide interface expected by the WebUI Cloak card:
 *   write '-'         -> clear all rules
 *   write '+<path>'   -> add a manual hide rule (prefix match on '/' boundary)
 *   write '&<path>'   -> add an AppCloak-supplement hide rule
 *   write '-<path>'   -> remove one rule
 *   write '@global'   -> apply rules globally except root-authorized callers
 *   write '@deny'     -> apply rules only to NoMount-blocked UIDs
 *   write '@uid:<id>' -> allow this caller UID to see '&' AppCloak rules
 *   write '@appcloak-clear' -> clear only '&' rules and caller UIDs
 *   read              -> one rule per line
 * ===================================================================== */
#define NM_PATHHIDE_MAX_PATHS    256
#define NM_PATHHIDE_MAX_PATH_LEN 512
#define NM_PATHHIDE_MAX_APP_UIDS 256
#define NM_PATHHIDE_INODE_BLOOM_BITS 2048
#define NM_PATHHIDE_STORAGE_ROOTS 4
#define NM_PATHHIDE_STORAGE_ROOT_LEN 32

enum nm_pathhide_scope {
	NM_PATHHIDE_SCOPE_DENY = 0,
	NM_PATHHIDE_SCOPE_GLOBAL,
};

struct nm_pathhide_rule {
	char path[NM_PATHHIDE_MAX_PATH_LEN];
	dev_t dev;
	unsigned long ino;
	u16 storage_suffix_off;
	u16 storage_suffix_len;
	bool inode_valid;
	bool needs_path_match;
	bool under_storage;
	bool appcloak_scope;
};

struct nm_pathhide_storage_root {
	char path[NM_PATHHIDE_STORAGE_ROOT_LEN];
	dev_t dev;
	unsigned long ino;
	u16 len;
};

struct nm_pathhide_table {
	struct rcu_head rcu;
	u16 count;
	u16 appcloak_uid_count;
	u8 storage_root_count;
	u8 scope;
	bool has_path_rules;
	/* Two-hash 2-Kbit filter. The old single-word filter saturated quickly
	 * when AppCloak published tens of APK directories, turning inode_permission()
	 * into a linear rule scan on ordinary filesystem traffic. */
	unsigned long inode_bloom[BITS_TO_LONGS(NM_PATHHIDE_INODE_BLOOM_BITS)];
	u32 appcloak_uids[NM_PATHHIDE_MAX_APP_UIDS];
	struct nm_pathhide_storage_root storage_roots[NM_PATHHIDE_STORAGE_ROOTS];
	struct nm_pathhide_rule rules[];
};

static DEFINE_MUTEX(nm_pathhide_mutex);
static DEFINE_STATIC_KEY_FALSE(nm_pathhide_active);
static struct nm_pathhide_table __rcu *nm_pathhide_rules;
static struct proc_dir_entry *nm_pathhide_pde;
bool nomount_pathhide_match_path(const char *path);
static bool nm_pathhide_scope_matches(const struct nm_pathhide_table *table);
#ifdef CONFIG_KSU
extern bool __ksu_is_allow_uid(uid_t uid) __weak;
#endif

static bool nm_pathhide_caller_exempt(void)
{
	kuid_t euid = current_euid();

	if (uid_eq(euid, GLOBAL_ROOT_UID) ||
	    uid_eq(current_fsuid(), GLOBAL_ROOT_UID))
		return true;
#ifdef CONFIG_KSU
	if (!__ksu_is_allow_uid)
		return false;
	return __ksu_is_allow_uid(__kuid_val(current_uid()));
#else
	return false;
#endif
}

/* Source-integrated VFS checks handle normal inode rules. Path-only rules need
 * syscall fallbacks because inode_permission() does not receive a pathname.
 * Keep those probes off unless a directory, unresolved path, or zero-inode
 * target requires textual matching. */
#if defined(CONFIG_KPROBES) && defined(CONFIG_ARM64)
struct nm_pathhide_syscall_data {
	bool matched;
	bool close_result;
};

static bool nm_pathhide_syscalls_registered;

static bool nm_pathhide_match_user_filename(struct pt_regs *regs)
{
	struct pt_regs *user_regs = (struct pt_regs *)regs->regs[0];
	char path[NM_PATHHIDE_MAX_PATH_LEN];
	long len;

	if (!user_regs)
		return false;
	len = strncpy_from_user(path,
				(const char __user *)user_regs->regs[1], sizeof(path));
	if (len <= 0)
		return false;
	path[sizeof(path) - 1] = '\0';
	return path[0] == '/' && nomount_pathhide_match_path(path);
}

static int nm_pathhide_syscall_entry(struct kretprobe_instance *ri,
				      struct pt_regs *regs)
{
	struct nm_pathhide_syscall_data *data =
		(struct nm_pathhide_syscall_data *)ri->data;

	data->matched = nm_pathhide_match_user_filename(regs);
	data->close_result = false;
	return 0;
}

static int nm_pathhide_open_entry(struct kretprobe_instance *ri,
				   struct pt_regs *regs)
{
	struct nm_pathhide_syscall_data *data =
		(struct nm_pathhide_syscall_data *)ri->data;

	data->matched = nm_pathhide_match_user_filename(regs);
	data->close_result = data->matched;
	return 0;
}

static int nm_pathhide_syscall_exit(struct kretprobe_instance *ri,
				     struct pt_regs *regs)
{
	struct nm_pathhide_syscall_data *data =
		(struct nm_pathhide_syscall_data *)ri->data;
	long ret = (long)regs->regs[0];

	if (!data->matched)
		return 0;
	if (data->close_result && ret >= 0)
		close_fd((unsigned int)ret);
	regs_set_return_value(regs, -ENOENT);
	return 0;
}

static struct nm_pathhide_syscall_probe {
	const char *symbol;
	int (*entry)(struct kretprobe_instance *, struct pt_regs *);
	struct kretprobe probe;
	bool registered;
} nm_pathhide_syscall_probes[] = {
	{ .symbol = "__arm64_sys_faccessat2", .entry = nm_pathhide_syscall_entry },
	{ .symbol = "__arm64_sys_readlinkat", .entry = nm_pathhide_syscall_entry },
	{ .symbol = "__arm64_sys_openat", .entry = nm_pathhide_open_entry },
	{ .symbol = "__arm64_sys_openat2", .entry = nm_pathhide_open_entry },
};

static void nm_pathhide_register_syscall_hooks(void)
{
	unsigned int i;

	if (nm_pathhide_syscalls_registered)
		return;
	for (i = 0; i < ARRAY_SIZE(nm_pathhide_syscall_probes); i++) {
		struct nm_pathhide_syscall_probe *p = &nm_pathhide_syscall_probes[i];

		p->probe.kp.symbol_name = p->symbol;
		p->probe.entry_handler = p->entry;
		p->probe.handler = nm_pathhide_syscall_exit;
		p->probe.data_size = sizeof(struct nm_pathhide_syscall_data);
		p->probe.maxactive = 40;
		if (!register_kretprobe(&p->probe))
			p->registered = true;
	}
	nm_pathhide_syscalls_registered = true;
}

static void nm_pathhide_unregister_syscall_hooks(void)
{
	unsigned int i;

	if (!nm_pathhide_syscalls_registered)
		return;
	for (i = 0; i < ARRAY_SIZE(nm_pathhide_syscall_probes); i++) {
		struct nm_pathhide_syscall_probe *p = &nm_pathhide_syscall_probes[i];

		if (p->registered) {
			unregister_kretprobe(&p->probe);
			p->registered = false;
		}
	}
	nm_pathhide_syscalls_registered = false;
}
#else
static inline void nm_pathhide_register_syscall_hooks(void) { }
static inline void nm_pathhide_unregister_syscall_hooks(void) { }
#endif

static struct nm_pathhide_table *nm_pathhide_alloc(unsigned int count)
{
	struct nm_pathhide_table *table;

	if (count > NM_PATHHIDE_MAX_PATHS)
		return NULL;
	table = kvzalloc(struct_size(table, rules, count), GFP_KERNEL);
	if (table)
		table->count = count;
	return table;
}

static bool nm_pathhide_scope_matches(const struct nm_pathhide_table *table)
{
	if (table->scope == NM_PATHHIDE_SCOPE_GLOBAL)
		return true;
	return nomount_is_uid_blocked(__kuid_val(current_fsuid()));
}

static bool nm_pathhide_rule_matches(const struct nm_pathhide_table *table,
				     const struct nm_pathhide_rule *rule,
				     bool manual_scope, uid_t caller_uid)
{
	if (!rule->appcloak_scope)
		return manual_scope;
	if (!table->appcloak_uid_count)
		return false;
	int i;

	for (i = 0; i < table->appcloak_uid_count; i++) {
		if (table->appcloak_uids[i] == caller_uid)
			return true;
	}
	return false;
}

static __always_inline u64 nm_pathhide_inode_key(dev_t dev, unsigned long ino)
{
	return ((u64)new_encode_dev(dev) << 32) ^ (u64)ino;
}

static __always_inline bool nm_pathhide_inode_maybe(
		const struct nm_pathhide_table *table, dev_t dev, unsigned long ino)
{
	u64 key = nm_pathhide_inode_key(dev, ino);
	u32 first = hash_64(key, 11);
	u32 second = hash_64(key ^ 0x9e3779b97f4a7c15ULL, 11);

	return test_bit(first, table->inode_bloom) &&
	       test_bit(second, table->inode_bloom);
}

static __always_inline void nm_pathhide_inode_bloom_add(
		struct nm_pathhide_table *table, dev_t dev, unsigned long ino)
{
	u64 key = nm_pathhide_inode_key(dev, ino);

	__set_bit(hash_64(key, 11), table->inode_bloom);
	__set_bit(hash_64(key ^ 0x9e3779b97f4a7c15ULL, 11),
		  table->inode_bloom);
}

static void nm_pathhide_copy_storage_roots(struct nm_pathhide_table *to,
					  const struct nm_pathhide_table *from)
{
	to->storage_root_count = from->storage_root_count;
	memcpy(to->storage_roots, from->storage_roots,
	       sizeof(to->storage_roots));
}

static void nm_pathhide_discover_storage_roots(struct nm_pathhide_table *table)
{
	static const char * const candidates[NM_PATHHIDE_STORAGE_ROOTS] = {
		"/storage/emulated/0",
		"/storage/self/primary",
		"/sdcard",
		"/mnt/sdcard",
	};
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(candidates); i++) {
		struct nm_pathhide_storage_root *root;
		struct path resolved;
		struct inode *inode;
		size_t len = strlen(candidates[i]);
		unsigned int j;

		if (len >= NM_PATHHIDE_STORAGE_ROOT_LEN ||
		    table->storage_root_count >= NM_PATHHIDE_STORAGE_ROOTS)
			continue;
		for (j = 0; j < table->storage_root_count; j++) {
			if (!strcmp(table->storage_roots[j].path, candidates[i]))
				break;
		}
		if (j < table->storage_root_count ||
		    kern_path(candidates[i], LOOKUP_FOLLOW, &resolved))
			continue;
		inode = d_backing_inode(resolved.dentry);
		if (!inode || !inode->i_sb || !inode->i_ino) {
			path_put(&resolved);
			continue;
		}
		if (table->storage_root_count &&
		    (inode->i_sb->s_dev != table->storage_roots[0].dev ||
		     inode->i_ino != table->storage_roots[0].ino)) {
			path_put(&resolved);
			continue;
		}
		root = &table->storage_roots[table->storage_root_count++];
		strscpy(root->path, candidates[i], sizeof(root->path));
		root->dev = inode->i_sb->s_dev;
		root->ino = inode->i_ino;
		root->len = len;
		path_put(&resolved);
	}
}

static void nm_pathhide_rule_set_storage(struct nm_pathhide_table *table,
					 struct nm_pathhide_rule *rule)
{
	size_t path_len = strnlen(rule->path, sizeof(rule->path));
	unsigned int i;

	rule->under_storage = false;
	rule->storage_suffix_off = 0;
	rule->storage_suffix_len = 0;
	if (!path_len || path_len >= sizeof(rule->path))
		return;
	for (i = 0; i < table->storage_root_count; i++) {
		const struct nm_pathhide_storage_root *root =
			&table->storage_roots[i];

		if (root->len > path_len ||
		    memcmp(rule->path, root->path, root->len) ||
		    (path_len != root->len && rule->path[root->len] != '/'))
			continue;
		rule->under_storage = true;
		rule->storage_suffix_off = root->len;
		rule->storage_suffix_len = path_len - root->len;
		return;
	}
}

/* Exact path or directory-prefix matching only.  The old strstr() rule made
 * "com.foo" also hide "com.foobar" and was the source of several app crashes. */
static bool nm_pathhide_text_matches(const struct nm_pathhide_table *table,
				     const char *path,
				     const struct nm_pathhide_rule *rule)
{
	size_t path_len, rule_len;
	unsigned int i;

	if (!path || rule->path[0] != '/')
		return false;
	path_len = strlen(path);
	rule_len = strnlen(rule->path, sizeof(rule->path));
	if (!rule_len || rule_len >= sizeof(rule->path))
		return false;
	if (rule->under_storage) {
		size_t suffix_off = rule->storage_suffix_off;
		size_t suffix_len = rule->storage_suffix_len;
		const char *suffix;

		if (suffix_off > rule_len || suffix_len > rule_len - suffix_off)
			return false;
		suffix = rule->path + suffix_off;
		for (i = 0; i < table->storage_root_count; i++) {
			const struct nm_pathhide_storage_root *root =
				&table->storage_roots[i];
			size_t match_len = root->len + suffix_len;

			if (root->len > path_len || match_len > path_len ||
			    memcmp(path, root->path, root->len) ||
			    memcmp(path + root->len, suffix, suffix_len))
				continue;
			if (match_len == path_len || path[match_len] == '/' ||
			    rule->path[rule_len - 1] == '/')
				return true;
		}
		return false;
	}
	if (path_len < rule_len || memcmp(path, rule->path, rule_len))
		return false;
	return path_len == rule_len || path[rule_len] == '/' ||
	       rule->path[rule_len - 1] == '/';
}

bool nomount_pathhide_match_path(const char *path)
{
	const struct nm_pathhide_table *table;
	bool hide = false;
	int i;

	if (unlikely(!path || !*path) ||
	    !static_branch_unlikely(&nm_pathhide_active))
		return false;
	rcu_read_lock();
	table = rcu_dereference(nm_pathhide_rules);
	if (table) {
		bool manual_scope = nm_pathhide_scope_matches(table);
		uid_t caller_uid = __kuid_val(current_fsuid());

		for (i = 0; i < table->count; i++) {
			if (nm_pathhide_rule_matches(table, &table->rules[i],
						      manual_scope, caller_uid) &&
			    nm_pathhide_text_matches(table, path,
						     &table->rules[i])) {
				hide = true;
				break;
			}
		}
	}
	rcu_read_unlock();
	if (hide && nm_pathhide_caller_exempt())
		hide = false;
	return hide;
}

bool nomount_pathhide_hide_inode(const struct inode *inode)
{
	const struct nm_pathhide_table *table;
	bool hide = false;
	int i;

	if (unlikely(!inode || !inode->i_sb) ||
	    !static_branch_unlikely(&nm_pathhide_active))
		return false;
	rcu_read_lock();
	table = rcu_dereference(nm_pathhide_rules);
	if (table) {
		bool manual_scope = nm_pathhide_scope_matches(table);
		uid_t caller_uid = __kuid_val(current_fsuid());

		if (!nm_pathhide_inode_maybe(table, inode->i_sb->s_dev,
					       inode->i_ino))
			goto out;
		for (i = 0; i < table->count; i++) {
			const struct nm_pathhide_rule *rule = &table->rules[i];
			if (nm_pathhide_rule_matches(table, rule,
						      manual_scope, caller_uid) &&
			    rule->inode_valid && rule->dev == inode->i_sb->s_dev &&
			    rule->ino == inode->i_ino) {
				hide = true;
				break;
			}
		}
	}
out:
	rcu_read_unlock();
	if (hide && nm_pathhide_caller_exempt())
		hide = false;
	return hide;
}

bool nomount_pathhide_hide_dirent(const struct inode *dir, u64 ino,
				  const char *name, int namelen)
{
	const struct nm_pathhide_table *table;
	bool hide = false;
	int i;

	if (unlikely(!dir || !dir->i_sb || ino == 0 || namelen <= 0) ||
	    !static_branch_unlikely(&nm_pathhide_active))
		return false;
	rcu_read_lock();
	table = rcu_dereference(nm_pathhide_rules);
	if (table) {
		bool manual_scope = nm_pathhide_scope_matches(table);
		uid_t caller_uid = __kuid_val(current_fsuid());

		if (!nm_pathhide_inode_maybe(table, dir->i_sb->s_dev,
					       (unsigned long)ino))
			goto out;
		for (i = 0; i < table->count; i++) {
			const struct nm_pathhide_rule *rule = &table->rules[i];
			if (nm_pathhide_rule_matches(table, rule,
						      manual_scope, caller_uid) &&
			    rule->inode_valid && rule->dev == dir->i_sb->s_dev &&
			    rule->ino == ino) {
				hide = true;
				break;
			}
		}
	}
out:
	rcu_read_unlock();
	if (hide && nm_pathhide_caller_exempt())
		hide = false;
	return hide;
}

/* /proc/maps and /proc/fd normally hit the identity fast path.  d_path() is
 * only needed for a directory-prefix rule whose descendant has another inode. */
bool nomount_pathhide_hide_path(const struct path *path)
{
	const struct nm_pathhide_table *table;
	const struct inode *inode;
	bool need_text = false;
	char *buf, *name;
	int i;

	if (unlikely(!path || !path->dentry) ||
	    !static_branch_unlikely(&nm_pathhide_active))
		return false;
	inode = d_backing_inode(path->dentry);
	if (nomount_pathhide_hide_inode(inode))
		return true;
	rcu_read_lock();
	table = rcu_dereference(nm_pathhide_rules);
	if (table)
		need_text = table->has_path_rules;
	rcu_read_unlock();
	if (!need_text)
		return false;
	buf = (char *)__get_free_page(GFP_KERNEL);
	if (!buf)
		return false;
	name = d_path(path, buf, PAGE_SIZE);
	i = !IS_ERR(name) && nomount_pathhide_match_path(name);
	free_page((unsigned long)buf);
	return i;
}

static int nm_pathhide_add(const char *path, bool appcloak_scope)
{
	struct nm_pathhide_table *old, *new;
	struct path resolved;
	struct inode *inode;
	int i, len, ret = 0;

	len = strlen(path);
	if (len <= 0 || len >= NM_PATHHIDE_MAX_PATH_LEN || path[0] != '/')
		return -EINVAL;
	mutex_lock(&nm_pathhide_mutex);
	old = rcu_dereference_protected(nm_pathhide_rules,
					lockdep_is_held(&nm_pathhide_mutex));
	for (i = 0; old && i < old->count; i++)
		if (old->rules[i].appcloak_scope == appcloak_scope &&
		    !strcmp(old->rules[i].path, path))
			goto out;
	if (old && old->count >= NM_PATHHIDE_MAX_PATHS) {
		ret = -ENOSPC;
		goto out;
	}
	new = nm_pathhide_alloc(old ? old->count + 1 : 1);
	if (!new) {
		ret = -ENOMEM;
		goto out;
	}
	new->scope = old ? old->scope : NM_PATHHIDE_SCOPE_GLOBAL;
	new->appcloak_uid_count = old ? old->appcloak_uid_count : 0;
	if (old) {
		memcpy(new->rules, old->rules, old->count * sizeof(*new->rules));
		nm_pathhide_copy_storage_roots(new, old);
		memcpy(new->appcloak_uids, old->appcloak_uids,
		       sizeof(new->appcloak_uids));
	}
	strscpy(new->rules[new->count - 1].path, path,
		sizeof(new->rules[new->count - 1].path));
	new->rules[new->count - 1].appcloak_scope = appcloak_scope;
	nm_pathhide_discover_storage_roots(new);
	for (i = 0; i < new->count; i++)
		nm_pathhide_rule_set_storage(new, &new->rules[i]);
	/* A trailing slash denotes a directory-prefix rule. */
	new->rules[new->count - 1].needs_path_match = path[len - 1] == '/';
	if (!kern_path(path, LOOKUP_FOLLOW, &resolved)) {
		inode = d_backing_inode(resolved.dentry);
		if (inode && inode->i_sb) {
			new->rules[new->count - 1].dev = inode->i_sb->s_dev;
			new->rules[new->count - 1].ino = inode->i_ino;
			new->rules[new->count - 1].inode_valid = inode->i_ino != 0;
			new->rules[new->count - 1].needs_path_match |=
				S_ISDIR(inode->i_mode) || !new->rules[new->count - 1].inode_valid;
		} else {
			new->rules[new->count - 1].needs_path_match = true;
		}
		path_put(&resolved);
	} else {
		new->rules[new->count - 1].needs_path_match = true;
	}
	for (i = 0; i < new->count; i++) {
		new->has_path_rules |= new->rules[i].needs_path_match;
		if (new->rules[i].inode_valid)
			nm_pathhide_inode_bloom_add(new, new->rules[i].dev,
						      new->rules[i].ino);
	}
	if (new->has_path_rules)
		nm_pathhide_register_syscall_hooks();
	rcu_assign_pointer(nm_pathhide_rules, new);
	if (!old) {
		static_branch_enable(&nm_pathhide_active);
	}
	if (!new->has_path_rules)
		nm_pathhide_unregister_syscall_hooks();
	if (old)
		kvfree_rcu(old, rcu);
out:
	mutex_unlock(&nm_pathhide_mutex);
	return ret;
}

static int nm_pathhide_remove(const char *path)
{
	struct nm_pathhide_table *old, *new = NULL;
	int i, j, found = -1, ret = 0;

	mutex_lock(&nm_pathhide_mutex);
	old = rcu_dereference_protected(nm_pathhide_rules,
					lockdep_is_held(&nm_pathhide_mutex));
	if (!old) {
		ret = *path ? -ENOENT : 0;
		goto out;
	}
	if (*path) {
		for (i = 0; i < old->count; i++)
			if (!old->rules[i].appcloak_scope &&
			    !strcmp(old->rules[i].path, path)) { found = i; break; }
		if (found < 0) { ret = -ENOENT; goto out; }
	}
	if (*path && old->count > 1) {
		new = nm_pathhide_alloc(old->count - 1);
		if (!new) { ret = -ENOMEM; goto out; }
		new->scope = old->scope;
		new->appcloak_uid_count = old->appcloak_uid_count;
		nm_pathhide_copy_storage_roots(new, old);
		memcpy(new->appcloak_uids, old->appcloak_uids,
		       sizeof(new->appcloak_uids));
		for (i = 0, j = 0; i < old->count; i++) {
			if (i == found) continue;
			new->rules[j] = old->rules[i];
			new->has_path_rules |= new->rules[j].needs_path_match;
			if (new->rules[j].inode_valid)
				nm_pathhide_inode_bloom_add(new, new->rules[j].dev,
							      new->rules[j].ino);
			j++;
		}
	}
	rcu_assign_pointer(nm_pathhide_rules, new);
	if (!new) {
		static_branch_disable(&nm_pathhide_active);
		nm_pathhide_unregister_syscall_hooks();
	} else if (new->has_path_rules)
		nm_pathhide_register_syscall_hooks();
	else
		nm_pathhide_unregister_syscall_hooks();
	kvfree_rcu(old, rcu);
out:
	mutex_unlock(&nm_pathhide_mutex);
	return ret;
}

static int nm_pathhide_set_scope(const char *scope)
{
	struct nm_pathhide_table *old, *new;
	u8 value;

	if (!strcmp(scope, "deny")) value = NM_PATHHIDE_SCOPE_DENY;
	else if (!strcmp(scope, "global")) value = NM_PATHHIDE_SCOPE_GLOBAL;
	else return -EINVAL;
	mutex_lock(&nm_pathhide_mutex);
	old = rcu_dereference_protected(nm_pathhide_rules,
					lockdep_is_held(&nm_pathhide_mutex));
	if (!old) { mutex_unlock(&nm_pathhide_mutex); return 0; }
	new = nm_pathhide_alloc(old->count);
	if (!new) { mutex_unlock(&nm_pathhide_mutex); return -ENOMEM; }
	memcpy(new->rules, old->rules, old->count * sizeof(*new->rules));
	nm_pathhide_copy_storage_roots(new, old);
	new->scope = value;
	new->appcloak_uid_count = old->appcloak_uid_count;
	memcpy(new->appcloak_uids, old->appcloak_uids, sizeof(new->appcloak_uids));
	new->has_path_rules = old->has_path_rules;
	bitmap_copy(new->inode_bloom, old->inode_bloom,
		    NM_PATHHIDE_INODE_BLOOM_BITS);
	rcu_assign_pointer(nm_pathhide_rules, new);
	kvfree_rcu(old, rcu);
	mutex_unlock(&nm_pathhide_mutex);
	return 0;
}

static int nm_pathhide_add_uid(const char *value)
{
	struct nm_pathhide_table *old, *new;
	char *end;
	unsigned long uid;
	u16 i;

	uid = simple_strtoul(value, &end, 10);
	if (!*value || *end || uid > 0xffffffffUL)
		return -EINVAL;
	mutex_lock(&nm_pathhide_mutex);
	old = rcu_dereference_protected(nm_pathhide_rules,
					lockdep_is_held(&nm_pathhide_mutex));
	for (i = 0; old && i < old->appcloak_uid_count; i++) {
		if (old->appcloak_uids[i] == (u32)uid) {
			mutex_unlock(&nm_pathhide_mutex);
			return 0;
		}
	}
	if (!old) {
		new = nm_pathhide_alloc(0);
		if (!new) {
			mutex_unlock(&nm_pathhide_mutex);
			return -ENOMEM;
		}
	} else {
		if (old->appcloak_uid_count >= NM_PATHHIDE_MAX_APP_UIDS) {
			mutex_unlock(&nm_pathhide_mutex);
			return -ENOSPC;
		}
		new = nm_pathhide_alloc(old->count);
		if (!new) {
			mutex_unlock(&nm_pathhide_mutex);
			return -ENOMEM;
		}
		memcpy(new->rules, old->rules, old->count * sizeof(*new->rules));
		new->scope = old->scope;
		new->has_path_rules = old->has_path_rules;
		nm_pathhide_copy_storage_roots(new, old);
		bitmap_copy(new->inode_bloom, old->inode_bloom,
			    NM_PATHHIDE_INODE_BLOOM_BITS);
		memcpy(new->appcloak_uids, old->appcloak_uids,
		       sizeof(new->appcloak_uids));
		new->appcloak_uid_count = old->appcloak_uid_count;
	}
	new->appcloak_uids[new->appcloak_uid_count++] = (u32)uid;
	rcu_assign_pointer(nm_pathhide_rules, new);
	if (!old)
		static_branch_enable(&nm_pathhide_active);
	else
		kvfree_rcu(old, rcu);
	mutex_unlock(&nm_pathhide_mutex);
	return 0;
}

static int nm_pathhide_clear_appcloak(void)
{
	struct nm_pathhide_table *old, *new = NULL;
	int i, j, appcloak_count = 0;

	mutex_lock(&nm_pathhide_mutex);
	old = rcu_dereference_protected(nm_pathhide_rules,
					lockdep_is_held(&nm_pathhide_mutex));
	if (!old) {
		mutex_unlock(&nm_pathhide_mutex);
		return 0;
	}
	for (i = 0; i < old->count; i++) {
		if (old->rules[i].appcloak_scope)
			appcloak_count++;
	}
	if (old->count == appcloak_count) {
		rcu_assign_pointer(nm_pathhide_rules, NULL);
		static_branch_disable(&nm_pathhide_active);
		nm_pathhide_unregister_syscall_hooks();
		kvfree_rcu(old, rcu);
		mutex_unlock(&nm_pathhide_mutex);
		return 0;
	}
	new = nm_pathhide_alloc(old->count - appcloak_count);
	if (!new) {
		mutex_unlock(&nm_pathhide_mutex);
		return -ENOMEM;
	}
	new->scope = old->scope;
	nm_pathhide_copy_storage_roots(new, old);
	for (i = 0, j = 0; i < old->count; i++) {
		if (old->rules[i].appcloak_scope)
			continue;
		new->rules[j] = old->rules[i];
		new->has_path_rules |= new->rules[j].needs_path_match;
		if (new->rules[j].inode_valid)
			nm_pathhide_inode_bloom_add(new, new->rules[j].dev,
							  new->rules[j].ino);
		j++;
	}
	rcu_assign_pointer(nm_pathhide_rules, new);
	if (new->has_path_rules)
		nm_pathhide_register_syscall_hooks();
	else
		nm_pathhide_unregister_syscall_hooks();
	kvfree_rcu(old, rcu);
	mutex_unlock(&nm_pathhide_mutex);
	return 0;
}

static int nm_pathhide_show(struct seq_file *m, void *v)
{
	const struct nm_pathhide_table *table;
	int i;

	rcu_read_lock();
	table = rcu_dereference(nm_pathhide_rules);
	if (table) {
		seq_printf(m, "@%s\n", table->scope == NM_PATHHIDE_SCOPE_GLOBAL ?
			   "global" : "deny");
		for (i = 0; i < table->count; i++)
			seq_printf(m, "%c%s\n",
				   table->rules[i].appcloak_scope ? '&' : '+',
				   table->rules[i].path);
		for (i = 0; i < table->appcloak_uid_count; i++)
			seq_printf(m, "@uid:%u\n", table->appcloak_uids[i]);
	} else {
		/* An empty table still defaults the next rule to global scope. */
		seq_puts(m, "@global\n");
	}
	rcu_read_unlock();
	return 0;
}

static int nm_pathhide_open(struct inode *inode, struct file *file)
{
	return single_open(file, nm_pathhide_show, NULL);
}

static ssize_t nm_pathhide_write(struct file *file, const char __user *ubuf,
				 size_t len, loff_t *off)
{
	char *buf;
	int ret;
	size_t write_len = len;

	if (len <= 0)
		return 0;
	if (len > NM_PATHHIDE_MAX_PATH_LEN + 1)
		return -E2BIG;
	buf = kmalloc(len + 1, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;
	if (copy_from_user(buf, ubuf, len)) {
		kfree(buf);
		return -EFAULT;
	}
	buf[len] = '\0';
	while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r' ||
			   buf[len - 1] == ' ' || buf[len - 1] == '\t'))
		buf[--len] = '\0';

	if (buf[0] == '+')
		ret = nm_pathhide_add(buf + 1, false);
	else if (buf[0] == '&')
		ret = nm_pathhide_add(buf + 1, true);
	else if (buf[0] == '-')
		ret = nm_pathhide_remove(buf + 1);
	else if (!strncmp(buf, "@uid:", 5))
		ret = nm_pathhide_add_uid(buf + 5);
	else if (!strcmp(buf, "@appcloak-clear"))
		ret = nm_pathhide_clear_appcloak();
	else if (buf[0] == '@')
		ret = nm_pathhide_set_scope(buf + 1);
	else
		ret = -EINVAL;
	kfree(buf);
	/* proc writes must report the caller's original byte count. Returning the
	 * newline-trimmed length is a short write, so shells report EIO even though
	 * the rule was already changed. */
	return ret ? ret : (ssize_t)write_len;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)
static const struct proc_ops nm_pathhide_proc_ops = {
	.proc_open	= nm_pathhide_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
	.proc_write	= nm_pathhide_write,
};
#else
static const struct file_operations nm_pathhide_fops = {
	.open		= nm_pathhide_open,
	.read		= seq_read,
	.llseek		= seq_lseek,
	.release	= single_release,
	.write		= nm_pathhide_write,
};
#endif

static int __init nomount_pathhide_init(void)
{
	RCU_INIT_POINTER(nm_pathhide_rules, NULL);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)
	nm_pathhide_pde = proc_create("pathhide", 0644, NULL, &nm_pathhide_proc_ops);
#else
	nm_pathhide_pde = proc_create("pathhide", 0644, NULL, &nm_pathhide_fops);
#endif
	if (!nm_pathhide_pde)
		return -ENOMEM;
	pr_info("nomount: v%d PathHide compatibility interface ready\n",
		NOMOUNT_VERSION);
	return 0;
}

static void nomount_pathhide_exit(void)
{
	struct nm_pathhide_table *table;

	if (nm_pathhide_pde) {
		remove_proc_entry("pathhide", NULL);
		nm_pathhide_pde = NULL;
	}
	mutex_lock(&nm_pathhide_mutex);
	table = rcu_dereference_protected(nm_pathhide_rules,
					  lockdep_is_held(&nm_pathhide_mutex));
	RCU_INIT_POINTER(nm_pathhide_rules, NULL);
	if (table)
		static_branch_disable(&nm_pathhide_active);
	nm_pathhide_unregister_syscall_hooks();
	mutex_unlock(&nm_pathhide_mutex);
	synchronize_rcu();
	kvfree(table);
}
