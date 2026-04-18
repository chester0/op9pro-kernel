import sys

# susfs.c — insert stub body before "/* susfs_init */" marker
c_path = "/work/kernel3/fs/susfs.c"
with open(c_path) as f:
    src = f.read()
marker = "/* susfs_init */\nvoid susfs_init(void) {"
stub = "void susfs_set_i_state_on_external_dir(void __user **user_info) {}\n\n/* susfs_init */\nvoid susfs_init(void) {"
if marker not in src:
    print("ERROR: c marker not found")
    sys.exit(1)
if "susfs_set_i_state_on_external_dir" in src:
    print("SKIP: c stub already present")
else:
    src = src.replace(marker, stub, 1)
    with open(c_path, "w") as f:
        f.write(src)
    print("OK: added c stub")

# susfs.h — insert declaration before "/* susfs_init */" marker
h_path = "/work/kernel3/include/linux/susfs.h"
with open(h_path) as f:
    hsrc = f.read()
h_marker = "/* susfs_init */\nvoid susfs_init(void);"
h_stub = "void susfs_set_i_state_on_external_dir(void __user **user_info);\n\n/* susfs_init */\nvoid susfs_init(void);"
if h_marker not in hsrc:
    print("ERROR: h marker not found")
    sys.exit(1)
if "susfs_set_i_state_on_external_dir" in hsrc:
    print("SKIP: h decl already present")
else:
    hsrc = hsrc.replace(h_marker, h_stub, 1)
    with open(h_path, "w") as f:
        f.write(hsrc)
    print("OK: added h decl")
