#!/system/bin/sh

printf %s - > /proc/pathhide 2>/dev/null || true
rm -rf /data/adb/nomount
rm -rf /data/system/nomount_appcloak
