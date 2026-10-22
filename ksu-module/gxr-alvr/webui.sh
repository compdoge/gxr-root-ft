#!/system/bin/sh
# Helper for the module WebUI (webroot/index.html). The KernelSU Manager invokes
# this as root. It validates its arguments, reads/writes the module's option
# files, restarts / pauses / resumes the relay, and exports the logs. Output is
# machine-readable: one "key=value" per line (the page parses it).
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/gxr-alvr
LOG=/data/local/tmp/gxr_alvr.log
PAUSED="$MODDIR/paused"
TRACE=/sys/kernel/tracing

readval() { [ -f "$MODDIR/$1" ] && cat "$MODDIR/$1" 2>/dev/null; }

# pkill is not guaranteed to be on PATH in the minimal shell the Manager runs
# with (same workaround as customize.sh and supervise.sh).
kill_matching() {
  /system/bin/pkill "$@" 2>/dev/null && return 0
  pkill "$@" 2>/dev/null && return 0
  return 1
}

# numval <text> -> canonical "%.3f" on stdout, exit 1 when it is not a number in (0,100]
numval() {
  case "$1" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac
  awk -v a="$1" 'BEGIN { if (a + 0 <= 0 || a + 0 > 100) exit 1; printf "%.3f", a + 0 }'
}

case "$1" in
  status)
    echo "pc=$(readval pc)"
    echo "port=$(readval port)"
    echo "mirror=$(readval mirror)"
    echo "tongue=$(readval tongue)"
    echo "verbose=$([ -f "$MODDIR/verbose" ] && echo 1 || echo 0)"
    echo "paused=$([ -f "$PAUSED" ] && echo 1 || echo 0)"
    echo "dilmin=$(readval dilmin)"
    echo "dilmax=$(readval dilmax)"
    echo "dillock=$([ -f "$MODDIR/dillock" ] && echo 1 || echo 0)"
    dv=""
    if [ -f "$MODDIR/devopts" ]; then dv=$(sed 's/ /=/' "$MODDIR/devopts" | tr '\n' ';'); dv=${dv%;}; fi
    echo "devopts=$dv"
    echo "pid=$(pidof gxr_alvr 2>/dev/null)"
    echo "ip=$(ip -4 addr show 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print $2}' | tr '\n' ',')"
    echo "armed=$(grep -a 'gxr_alvr: v' "$LOG" 2>/dev/null | tail -n1)"
    echo "tail=$(tail -n 12 "$LOG" 2>/dev/null | tr '\n' '~')"
    ;;
  set)
    # set <pc|-|auto> <port> <tongue 0|1> <verbose 0|1>
    PC="$2"; PORT="$3"; TONGUE="$4"; VERB="$5"
    case "$PC" in
      ""|-|auto) rm -f "$MODDIR/pc" 2>/dev/null ;;
      *[!0-9.]*) echo "error=invalid PC address"; exit 2 ;;
      *) printf '%s\n' "$PC" > "$MODDIR/pc" ;;
    esac
    case "$PORT" in
      ""|*[!0-9]*) echo "error=invalid port"; exit 2 ;;
      *) if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
           printf '%s\n' "$PORT" > "$MODDIR/port"
         else echo "error=invalid port"; exit 2; fi ;;
    esac
    if [ "$TONGUE" = "1" ]; then rm -f "$MODDIR/tongue" 2>/dev/null; else printf '0\n' > "$MODDIR/tongue"; fi
    if [ "$VERB" = "1" ]; then : > "$MODDIR/verbose"; else rm -f "$MODDIR/verbose" 2>/dev/null; fi
    sh "$MODDIR/action.sh" >/dev/null 2>&1
    sleep 1
    echo "ok=1"
    echo "pid=$(pidof gxr_alvr 2>/dev/null)"
    ;;
  setdev)
    # setdev <--flag=value;--flag=value | ->  -> write devopts (validated) + restart
    SPEC="$2"
    if [ -z "$SPEC" ] || [ "$SPEC" = "-" ]; then
      rm -f "$MODDIR/devopts" 2>/dev/null
    else
      if ! printf '%s' "$SPEC" | grep -qE '^[A-Za-z0-9._,:/+;=-]+$'; then
        echo "error=invalid characters in dev options"; exit 2
      fi
      BAD=$(printf '%s' "$SPEC" | tr ';' '\n' | grep -vE '^--[a-z0-9-]+=[A-Za-z0-9._,:/+-]+$')
      if [ -n "$BAD" ]; then echo "error=bad dev option: $BAD"; exit 2; fi
      printf '%s\n' "$SPEC" | tr ';' '\n' | sed 's/=/ /' > "$MODDIR/devopts"
    fi
    sh "$MODDIR/action.sh" >/dev/null 2>&1
    sleep 1
    echo "ok=1"
    echo "pid=$(pidof gxr_alvr 2>/dev/null)"
    ;;
  dilcal)
    # dilcal lock|unlock|reset|set <min> <max>
    # Freeze the learned dilation range, release it, forget it, or write a range by
    # hand. The relay owns the numbers - it writes dilmin/dilmax as it learns and
    # flushes them on a clean exit - so the order of the file operations matters:
    #   - reset/set must stop the relay BEFORE touching the files, or that exit
    #     flush overwrites what was just written (or recreates what was deleted);
    #   - lock only adds the marker, so the values it freezes are the ones the
    #     running relay actually ended with.
    # Validation for "set" runs before anything is stopped: a typo must not
    # interrupt tracking.
    if [ -f "$PAUSED" ]; then
      echo "error=module is paused; resume it first"
      exit 1
    fi
    case "$2" in
      lock)
        LO=$(readval dilmin); HI=$(readval dilmax)
        if [ -z "$LO" ] || [ -z "$HI" ]; then
          echo "error=no learned dilation range yet (use face tracking first)"
          exit 1
        fi
        if ! awk -v a="$LO" -v b="$HI" 'BEGIN { exit !(a + 0 > 0 && b + 0 > a + 0 && b + 0 <= 100) }'; then
          echo "error=stored dilation range is not usable ($LO..$HI)"
          exit 1
        fi
        : > "$MODDIR/dillock"
        ;;
      unlock)
        # An explicit --dil-min/--dil-max pair in devopts outranks these files and
        # re-locks the relay on every start; pretending to unlock would lie.
        if grep -q -e '^--dil-min ' -e '^--dil-max ' "$MODDIR/devopts" 2>/dev/null; then
          echo "error=--dil-min/--dil-max are set in Developer options; clear them first"
          exit 1
        fi
        rm -f "$MODDIR/dillock" 2>/dev/null
        ;;
      reset|set)
        if grep -q -e '^--dil-min ' -e '^--dil-max ' "$MODDIR/devopts" 2>/dev/null; then
          echo "error=--dil-min/--dil-max are set in Developer options; clear them first"
          exit 1
        fi
        if [ "$2" = "set" ]; then
          LO=$(numval "$3") || { echo "error=min must be a number in 0..100"; exit 1; }
          HI=$(numval "$4") || { echo "error=max must be a number in 0..100"; exit 1; }
          awk -v a="$LO" -v b="$HI" 'BEGIN { exit !(b + 0 > a + 0) }' \
            || { echo "error=min must be below max"; exit 1; }
        fi
        kill_matching -f "$MODDIR/supervise.sh --loop"
        sleep 1
        kill_matching -x gxr_alvr
        sleep 1
        pidof gxr_alvr >/dev/null 2>&1 && { kill_matching -9 -x gxr_alvr; sleep 1; }
        if [ "$2" = "set" ]; then
          printf '%s\n' "$LO" > "$MODDIR/dilmin"
          printf '%s\n' "$HI" > "$MODDIR/dilmax"
          : > "$MODDIR/dillock"
        else
          rm -f "$MODDIR/dillock" "$MODDIR/dilmin" "$MODDIR/dilmax" 2>/dev/null
        fi
        ;;
      *)
        echo "error=usage: dilcal lock|unlock|reset|set <min> <max>"
        exit 2
        ;;
    esac
    sh "$MODDIR/action.sh" >/dev/null 2>&1
    sleep 1
    echo "ok=1"
    echo "dilmin=$(readval dilmin)"
    echo "dilmax=$(readval dilmax)"
    echo "dillock=$([ -f "$MODDIR/dillock" ] && echo 1 || echo 0)"
    echo "pid=$(pidof gxr_alvr 2>/dev/null)"
    ;;
  pause)
    # Stop the supervisor first (killing the relay alone would just make it
    # respawn), then let the relay exit on its own: SIGTERM makes it disable its
    # probes and clear uprobe_events on the way out, so a paused module is
    # genuinely not tracing anything. This is the honest A/B switch for
    # "is the module making my headset hot": one tap, no reboot, no zip swap.
    kill_matching -f "$MODDIR/supervise.sh --loop"
    sleep 1
    kill_matching -x gxr_alvr
    sleep 1
    if pidof gxr_alvr >/dev/null 2>&1; then
      echo "error=relay did not stop (pid $(pidof gxr_alvr))"; exit 1
    fi
    # Cover the case where the relay had been killed from outside earlier, so
    # nothing disarmed its probes: turn our tracing off explicitly.
    echo 0 > "$TRACE/tracing_on" 2>/dev/null
    echo 0 > "$TRACE/events/uprobes/pten/enable" 2>/dev/null
    echo 0 > "$TRACE/events/uprobes/dir/enable" 2>/dev/null
    echo 0 > "$TRACE/events/uprobes/bs/enable" 2>/dev/null
    echo 0 > "$TRACE/events/uprobes/jaw/enable" 2>/dev/null
    echo 0 > "$TRACE/events/uprobes/tongue/enable" 2>/dev/null
    : > "$PAUSED"
    echo "ok=1"
    echo "paused=1"
    ;;
  resume)
    rm -f "$PAUSED" 2>/dev/null
    sh "$MODDIR/action.sh" >/dev/null 2>&1
    sleep 1
    echo "ok=1"
    echo "paused=0"
    echo "pid=$(pidof gxr_alvr 2>/dev/null)"
    ;;
  exportlog)
    # Copy the logs where the user can reach them (Downloads on internal storage),
    # overwriting the previous copy instead of piling up files. Uses `cat >` so it
    # does not depend on cp being allowed to write to /sdcard.
    DST=/sdcard/Download
    mkdir -p "$DST" 2>/dev/null
    n=0
    for pair in "gxr-alvr-log.txt:$LOG" "gxr-alvr-log-previous.txt:$LOG.1" \
                "gxr-alvr-install-log.txt:/data/local/tmp/gxr_alvr_install.log"; do
      out="${pair%%:*}"; src="${pair#*:}"
      if [ -f "$src" ]; then
        cat "$src" > "$DST/$out" 2>/dev/null && {
          # The WebUI runs as root with a restrictive umask: without this the copy
          # lands root-only and cannot be read back over adb either.
          chmod 666 "$DST/$out" 2>/dev/null
          n=$((n + 1))
        }
      fi
    done
    echo "ok=$n"
    echo "dir=$DST"
    echo "files=$(ls -l "$DST"/gxr-alvr-log.txt "$DST"/gxr-alvr-log-previous.txt 2>/dev/null | awk '{print $5}' | tr '\n' ',')"
    ;;
  test)
    # test <ip>  -> best-effort reachability check from the headset
    IP="$2"
    case "$IP" in *[!0-9.]*|"") echo "ping=bad"; exit 2 ;; esac
    if command -v timeout >/dev/null 2>&1; then
      timeout 2 ping -c 1 "$IP" >/dev/null 2>&1 && echo "ping=ok" || echo "ping=fail"
    else
      ping -c 1 -W 1 "$IP" >/dev/null 2>&1 && echo "ping=ok" || echo "ping=fail"
    fi
    ;;
  *)
    echo "error=usage: status | set <pc|-|auto> <port> <tongue> <verbose> | setdev <spec|-> | dilcal lock|unlock|reset | pause | resume | exportlog | test <ip>"
    exit 2
    ;;
esac
