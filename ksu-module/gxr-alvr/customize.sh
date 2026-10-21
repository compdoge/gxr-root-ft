#!/system/bin/sh
# KernelSU module installer customization (sourced by the installer after extraction).
set_perm $MODPATH/gxr_alvr    0 0 0755
set_perm $MODPATH/service.sh  0 0 0755
set_perm $MODPATH/action.sh   0 0 0755
set_perm $MODPATH/supervise.sh 0 0 0755
set_perm $MODPATH/webui.sh    0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755
# Do NOT set permissions on $MODPATH/webroot -- KernelSU sets them itself.
# Preserve the user's option files across an in-place update. KernelSU extracts
# the new version to modules_update/<id> and, at boot, WIPES the old module dir
# and renames the new one into place -- so any pc/port/mirror/tongue/verbose/dev
# file left in the module dir is otherwise lost on every update. customize.sh
# runs while the OLD module dir still exists, so copy them forward here.
OLD=/data/adb/modules/gxr-alvr
KEPT=
if [ -n "$MODPATH" ] && [ -d "$MODPATH" ] && [ -d "$OLD" ]; then
  for f in pc port mirror tongue verbose dev devopts dilmin dilmax dillock; do
    if [ -f "$OLD/$f" ] && [ ! -e "$MODPATH/$f" ]; then
      cp -af "$OLD/$f" "$MODPATH/$f" 2>/dev/null && KEPT="$KEPT $f"
    fi
  done
fi
# Kill any relay still running from an OLDER module version (or a manual dev
# copy) so a stale binary can't keep streaming after an in-place update. The
# installer has a minimal PATH, so try several tools and, as a last resort, kill
# by pid. Logged so it can be inspected at /data/local/tmp/gxr_alvr_install.log.
# (The new relay starts on reboot -- KernelSU modules are not active until then.)
KLOG=/data/local/tmp/gxr_alvr_install.log
{
  echo "install: killing old gxr_alvr + supervisor (before: $(pidof gxr_alvr 2>/dev/null)); kept:${KEPT:- none}"
  # Supervisor first: killing the relay alone would just make it respawn it.
  /system/bin/pkill -f "supervise.sh --loop" 2>/dev/null
  pkill -f "supervise.sh --loop" 2>/dev/null
  sleep 1
  for p in $(pidof gxr_alvr 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  /system/bin/pkill -x gxr_alvr 2>/dev/null
  pkill -x gxr_alvr 2>/dev/null
  killall gxr_alvr 2>/dev/null
  sleep 1
  echo "install: after kill (pidof: $(pidof gxr_alvr 2>/dev/null))"
} >> "$KLOG" 2>&1
ui_print "- gxr-alvr: Galaxy XR face tracking relay installed"
ui_print "  reboot to activate this version (KernelSU modules load at boot)"
ui_print "  target: auto (LAN broadcast) -> VRCFT-ALVR module on UDP 41463"
ui_print "  set the PC's IP from the Manager: tap WebUI on this module"
