#!/system/bin/sh
# Remove all persistent NoMount state when the module is uninstalled.

printf %s - > /proc/pathhide 2>/dev/null || true
rm -rf /data/adb/nomount
rm -rf /data/system/nomount_appcloak
