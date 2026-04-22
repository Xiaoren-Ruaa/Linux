#!/bin/sh
# Magisk module installation script.
# Runs in the Magisk installer environment.

# Set permissions on binaries
set_perm_recursive "$MODPATH/system/bin" 0 0 0755 0755

# Set permissions on shared libraries
if [ -d "$MODPATH/system/lib64" ]; then
  set_perm_recursive "$MODPATH/system/lib64" 0 0 0755 0644
  # Create ldconfig-style symlinks expected by lsblk and similar tools
  cd "$MODPATH/system/lib64"
  for lib in libblkid libmount libuuid libsmartcols; do
    [ -f "${lib}.so" ] && ln -sf "/system/lib64/${lib}.so" "${lib}.so.1" 2>/dev/null || true
  done
fi

# Set SELinux contexts
chcon -R u:object_r:system_file:s0 "$MODPATH/system/bin" 2>/dev/null || true
[ -d "$MODPATH/system/lib64" ] && \
  chcon -R u:object_r:system_lib_file:s0 "$MODPATH/system/lib64" 2>/dev/null || true
