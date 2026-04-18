import sys

path = "/work/kernel3/fs/proc/fd.c"
with open(path) as f:
    src = f.read()

old = '\tseq_printf(m, "pos:\\t%lli\\nflags:\\t0%o\\nmnt_id:\\t%i\\n",\n\t\t   (long long)file->f_pos, f_flags,\n\t\t   real_mount(file->f_path.mnt)->mnt_id);'

new = '''#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\tmnt = real_mount(file->f_path.mnt);
\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) &&
\t\t\tmnt->mnt_id >= DEFAULT_SUS_MNT_ID) {
\t\tfor (; mnt->mnt_id >= DEFAULT_SUS_MNT_ID; mnt = mnt->mnt_parent) { }
\t}
\tseq_printf(m, "pos:\\t%lli\\nflags:\\t0%o\\nmnt_id:\\t%i\\n",
\t\t   (long long)file->f_pos, f_flags,
\t\t   mnt->mnt_id);
#else
\tseq_printf(m, "pos:\\t%lli\\nflags:\\t0%o\\nmnt_id:\\t%i\\n",
\t\t   (long long)file->f_pos, f_flags,
\t\t   real_mount(file->f_path.mnt)->mnt_id);
#endif'''

count = src.count(old)
if count != 1:
    print(f"ERROR: found {count} matches (expected 1)")
    sys.exit(1)

src = src.replace(old, new, 1)
with open(path, "w") as f:
    f.write(src)
print("OK: patched fd.c")
