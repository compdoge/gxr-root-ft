#!/system/bin/sh
# KernelSU module uninstall: stop the supervisor first (otherwise it would keep
# restarting the relay), then the relay itself.
# pkill is not guaranteed to be on PATH in the minimal uninstall shell, so try
# the absolute binary first (same workaround as customize/supervise/webui).
kill_matching() {
  /system/bin/pkill "$@" 2>/dev/null && return 0
  pkill "$@" 2>/dev/null && return 0
  return 1
}
kill_matching -f "supervise.sh --loop"
sleep 1
kill_matching -x gxr_alvr
