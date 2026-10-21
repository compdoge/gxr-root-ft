#!/system/bin/sh
# Resolve the relay config, then run the relay under a respawn loop. Both
# service.sh (boot) and action.sh (Manager Action button) call this, so the
# config is read in exactly one place.
#
# The supervisor exists for two reasons:
#   - the sender has a watchdog that EXITS when its main loop stalls, and
#   - nothing used to restart the relay after any exit, so one crash meant a
#     reboot or a manual Action tap.
# Because of it, a deliberate stop must kill the SUPERVISOR first: killing the
# relay alone would just make the supervisor start it again.
#
# Two exits are terminal and are NOT restarted: rc=5 (another live relay holds
# the lock) and rc=137 (something outside this module killed the relay). See the
# respawn loop below for why.
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/gxr-alvr
LOG=/data/local/tmp/gxr_alvr.log

# --loop <bin> <relay args...>: this is the supervisor itself.
if [ "$1" = "--loop" ]; then
  shift
  delay=2
  while :; do
    started=$(date +%s)
    "$@" </dev/null >>"$LOG" 2>&1
    rc=$?
    ran=$(( $(date +%s) - started ))
    if [ "$rc" = "5" ]; then
      # Another live relay holds the single-instance lock. Retrying cannot fix
      # that, it would only fight the instance that is already running.
      echo "gxr-alvr: relay exited rc=5 (another relay holds the lock); supervisor stopping" >>"$LOG"
      exit 0
    fi
    if [ "$rc" = "137" ]; then
      # 128+9: something OUTSIDE this module sent SIGKILL (on Android that is
      # usually lmkd under memory pressure, or a vendor/thermal policy killing
      # background work). That is a decision about this process, not a crash, so
      # do not overrule it: restarting means rebuilding every uprobe and asking
      # the kernel for the whole ring buffer again, which is exactly the load the
      # killer was trying to shed, and if it keeps happening the two of us fight.
      # The relay is not running now; start it again from the Manager (Action
      # button) or the WebUI when it suits you.
      echo "gxr-alvr: relay was killed from outside (rc=137 SIGKILL); not restarting. Tap Action or use the WebUI Pause/Resume to start it again" >>"$LOG"
      exit 0
    fi
    # Back off on repeated failure: without this, a relay that can never start
    # (e.g. a firmware update moved the probed symbols, so arming fails with
    # rc=3) is retried every 2 s forever and logs a line every 2 s. A run that
    # lasted long enough to be healthy resets it.
    [ "$ran" -ge 60 ] && delay=2
    echo "gxr-alvr: relay exited rc=$rc after ${ran}s; restarting in ${delay}s" >>"$LOG"
    sleep "$delay"
    delay=$((delay * 2))
    [ "$delay" -gt 60 ] && delay=60
  done
fi

# ---- config (see README.md, "Option files") ----
PC=$(cat "$MODDIR/pc" 2>/dev/null)
PORT=$(cat "$MODDIR/port" 2>/dev/null)
[ -z "$PORT" ] && PORT=41463
MIRROR=$(cat "$MODDIR/mirror" 2>/dev/null)
TONGUE=$(cat "$MODDIR/tongue" 2>/dev/null)
EXTRA=""
[ -n "$MIRROR" ] && EXTRA="$EXTRA --mirror-port $MIRROR"
[ "$TONGUE" = "0" ] && EXTRA="$EXTRA --tongue-extras 0"
[ -f "$MODDIR/verbose" ] && EXTRA="$EXTRA --verbose"
if [ -f "$MODDIR/devopts" ]; then
  if grep -qvE '^(--[a-z0-9-]+( [A-Za-z0-9._,:/+-]+)?)?$' "$MODDIR/devopts"; then
    echo "gxr-alvr: ignoring devopts (unexpected content)" >>"$LOG"
  else
    EXTRA="$EXTRA $(tr '\n' ' ' < "$MODDIR/devopts")"
  fi
fi

# Shipped binary. Dev opt-in only: create "$MODDIR/dev" to prefer a binary
# pushed to /data/local/tmp/gxr_alvr (see README.md, "Dev mode").
BIN="$MODDIR/gxr_alvr"
if [ -f "$MODDIR/dev" ] && [ -x /data/local/tmp/gxr_alvr ]; then
  BIN=/data/local/tmp/gxr_alvr
fi

# ---- stop the previous pair: supervisor first, or it resurrects the relay ----
pkill -f "$MODDIR/supervise.sh --loop" 2>/dev/null
sleep 1
pkill -x gxr_alvr 2>/dev/null
sleep 1
pidof gxr_alvr >/dev/null 2>&1 && { pkill -9 -x gxr_alvr 2>/dev/null; sleep 1; }

# ---- fresh log per start; the previous run is kept as .1 for diagnosis ----
[ -f "$LOG" ] && mv -f "$LOG" "$LOG.1"
# Keep the log readable by a non-root adb shell. The Manager's WebUI runs
# service.sh/action.sh as root with a restrictive umask, so the file the shell
# redirect below creates would otherwise come out root-only (0600) and could not
# be pulled for diagnosis - while a boot-time start would have produced 0666.
# Create it here with the mode everyone expects, before the redirect appends.
: >> "$LOG" 2>/dev/null
chmod 666 "$LOG" 2>/dev/null

# ---- start (EXTRA is a validated flag list, so word-splitting it is intended) ----
set -- "$BIN" --port "$PORT" --state-dir "$MODDIR"
[ -n "$PC" ] && set -- "$@" --pc "$PC"
for a in $EXTRA; do set -- "$@" "$a"; done
setsid sh "$MODDIR/supervise.sh" --loop "$@" &
sleep 1
echo "gxr-alvr: supervised relay=$BIN pid=$(pidof gxr_alvr) -> ${PC:-auto(broadcast)}:$PORT mirror=${MIRROR:-none}"
