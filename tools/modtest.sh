#!/usr/bin/env bash
# Offline harness for the module scripts and the sender's startup diagnostics.
# No device involved.
#   - supervise.sh: rc=137 must be terminal (no respawn); other rcs must retry;
#     rc=5 must retry a bounded number of times and then stop with a reason.
#   - webui.sh pause/resume/exportlog/dilcal logic, with the Android paths sandboxed.
#   - gxr_alvr.c: compiles with a host cc when one is available, keeps the
#     heartbeat off unprotected tracefs reads, keeps the watchdog's long-gap
#     message free of unsupported claims, and requires confirmation/rate limits
#     before a device-wide probe clear; the startup diagnostic, watchdog cases
#     and health-verdict wording are run through tools/relay_selftest.c.
#   - ksu-module/gxr-alvr/gxr_alvr: the tracked binary must embed the module.prop
#     version and the new log strings, with no compiler or source tree needed.
# The real scripts hardcode /data/local/tmp, /sys/kernel/tracing and
# /sdcard/Download, so each copy is rewritten to a scratch directory; the
# control flow is what is under test.
set -u
ROOT="${WORK:-$(mktemp -d)}"
SELF="${0//\\//}"          # accept both tools/modtest.sh and D:\...\tools\modtest.sh
MOD="$(cd "$(dirname "$SELF")/../ksu-module/gxr-alvr" && pwd)"
pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }
# expect <label> <expected> <actual>
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2] got [$3])"; fi; }

# ---------------------------------------------------------------- supervise.sh
echo "== supervise.sh =="
S="$ROOT/sup"
rm -rf "$S"; mkdir -p "$S/bin" "$S/tmp"
sed "s|/data/local/tmp/gxr_alvr.log|$S/tmp/gxr_alvr.log|" "$MOD/supervise.sh" > "$S/supervise.sh"
printf 'x\n' > "$S/module.prop"   # so MODDIR resolves to $S
cat > "$S/bin/relay137" <<'EOF'
#!/usr/bin/env sh
echo "relay-stub: about to die 137"
exit 137
EOF
cat > "$S/bin/relay1" <<'EOF'
#!/usr/bin/env sh
exit 1
EOF
chmod +x "$S/bin/relay137" "$S/bin/relay1"

"$S/bin/relay137" >/dev/null 2>&1   # sanity: stub itself exits 137
expect "stub exit code is 137" "137" "$?"

sh "$S/supervise.sh" --loop "$S/bin/relay137" >/dev/null 2>&1
expect "rc=137 -> supervisor exits" "0" "$?"
grep -q "rc=137 SIGKILL); not restarting" "$S/tmp/gxr_alvr.log" \
  && ok "rc=137 logged as terminal" || bad "rc=137 log line missing"
expect "rc=137 respawned 0 times" "1" "$(grep -c 'about to die 137' "$S/tmp/gxr_alvr.log")"

rm -f "$S/tmp/gxr_alvr.log"
( sh "$S/supervise.sh" --loop "$S/bin/relay1" >/dev/null 2>&1 ) &
sup=$!
sleep 7
kill "$sup" 2>/dev/null
wait "$sup" 2>/dev/null
n=$(grep -c 'relay exited rc=1' "$S/tmp/gxr_alvr.log" 2>/dev/null)
if [ "$n" -ge 2 ]; then ok "rc=1 still retries (attempts=$n)"; else bad "rc=1 did not retry (attempts=$n)"; fi

# rc=5 (another relay holds the lock): bounded retries, then an explicit stop.
# The old behaviour gave up on the first rc=5, which turned one lock collision
# into a permanent outage; the new one must not loop forever either.
rm -f "$S/tmp/gxr_alvr.log"
cat > "$S/bin/relay5" <<'EOF'
#!/usr/bin/env sh
echo "relay-stub: lock busy"
exit 5
EOF
chmod +x "$S/bin/relay5"
t0=$(date +%s)
sh "$S/supervise.sh" --loop "$S/bin/relay5" >/dev/null 2>&1
rc5=$?
elapsed=$(( $(date +%s) - t0 ))
expect "rc=5 supervisor exits gracefully" "0" "$rc5"
expect "rc=5 tried once plus LOCK_RETRY_MAX (3) retries" "4" "$(grep -c 'relay-stub: lock busy' "$S/tmp/gxr_alvr.log" 2>/dev/null)"
grep -q 'retry 1/3' "$S/tmp/gxr_alvr.log" && ok "rc=5 logs a numbered retry" || bad "rc=5 retry line missing"
grep -q 'retry 3/3' "$S/tmp/gxr_alvr.log" && ok "rc=5 stops retrying at the limit" || bad "rc=5 retry limit not logged"
grep -q 'lock still held by pid=.* after 3 retries' "$S/tmp/gxr_alvr.log" \
  && ok "rc=5 stop is explained, not silent" || bad "rc=5 stop line missing"
if [ "$elapsed" -le 20 ]; then ok "rc=5 bound is bounded in time (${elapsed}s)"; else bad "rc=5 took ${elapsed}s"; fi

# rc=5 once, then the holder is gone: the same supervisor must recover.
rm -f "$S/tmp/gxr_alvr.log" "$S/lock_once"
cat > "$S/bin/relay5once" <<EOF
#!/usr/bin/env sh
if [ -f "$S/lock_once" ]; then
  echo "relay-stub: started after lock retry"
  exit 0
fi
touch "$S/lock_once"
echo "relay-stub: lock busy once"
exit 5
EOF
chmod +x "$S/bin/relay5once"
sh "$S/supervise.sh" --loop "$S/bin/relay5once" >/dev/null 2>&1 &
sup5=$!
sleep 5
kill "$sup5" 2>/dev/null
wait "$sup5" 2>/dev/null
grep -q 'relay-stub: started after lock retry' "$S/tmp/gxr_alvr.log" \
  && ok "rc=5 recovers when the lock is released" || bad "rc=5 did not recover after the lock was freed"
grep -q 'retry 1/3' "$S/tmp/gxr_alvr.log" && ok "rc=5 recovery went through a retry" || bad "rc=5 recovery skipped the retry log"

# ------------------------------------------------------------------- webui.sh
echo "== webui.sh =="
W="$ROOT/wui"
rm -rf "$W"; mkdir -p "$W/module" "$W/tmp" "$W/trace/events/uprobes" "$W/sdcard/Download" "$W/bin"
sed -e "s|/data/local/tmp/gxr_alvr.log|$W/tmp/gxr_alvr.log|" \
    -e "s|/data/local/tmp/gxr_alvr_install.log|$W/tmp/gxr_alvr_install.log|" \
    -e "s|/sys/kernel/tracing|$W/trace|" \
    -e "s|/sdcard/Download|$W/sdcard/Download|" \
    -e "s|/data/adb/modules/gxr-alvr|$W/module|" "$MOD/webui.sh" > "$W/module/webui.sh"
printf 'id=gxr-alvr\n' > "$W/module/module.prop"
for e in pten dir bs jaw tongue; do mkdir -p "$W/trace/events/uprobes/$e"; printf '1\n' > "$W/trace/events/uprobes/$e/enable"; done
printf '1\n' > "$W/trace/tracing_on"
printf 'hello log\n' > "$W/tmp/gxr_alvr.log"
printf 'older\n' > "$W/tmp/gxr_alvr.log.1"
printf 'install\n' > "$W/tmp/gxr_alvr_install.log"

# stubs: pidof/pkill driven by a "running" marker; action.sh records a call.
cat > "$W/bin/pidof" <<EOF
#!/usr/bin/env sh
[ -f "$W/running" ] && { cat "$W/running"; exit 0; }
exit 1
EOF
cat > "$W/bin/pkill" <<EOF
#!/usr/bin/env sh
case "\$1" in
  -f) [ "\$2" = "$W/module/supervise.sh --loop" ] && touch "$W/sup_killed" ;;
  -x) rm -f "$W/running" ;;   # SIGTERM: the relay exits cleanly
esac
exit 0
EOF
cat > "$W/module/action.sh" <<EOF
#!/usr/bin/env sh
echo "12345" > "$W/running"
touch "$W/action_called"
EOF
chmod +x "$W/bin/pidof" "$W/bin/pkill" "$W/module/action.sh"
mkdir -p "$W/supervise_dir"
sed -i "s|\"\$MODDIR/supervise.sh --loop\"|$W/module/supervise.sh|" "$W/bin/pkill" 2>/dev/null || true
export PATH="$W/bin:$PATH"

# pause with a live relay
printf '777\n' > "$W/running"
out=$(sh "$W/module/webui.sh" pause 2>&1); rc=$?
expect "pause exit 0" "0" "$rc"
echo "$out" | grep -q "^ok=1$" && ok "pause reports ok=1" || bad "pause output: $out"
[ -f "$W/running" ] && bad "relay still running after pause" || ok "relay stopped"
[ -f "$W/module/paused" ] && ok "paused marker written" || bad "paused marker missing"
expect "tracing_on cleared" "0" "$(cat "$W/trace/tracing_on")"
expect "pten enable cleared"  "0" "$(cat "$W/trace/events/uprobes/pten/enable")"
expect "tongue enable cleared" "0" "$(cat "$W/trace/events/uprobes/tongue/enable")"
[ -f "$W/sup_killed" ] && ok "supervisor killed before relay (no respawn race)" || bad "supervisor not killed first"

# pause when the relay refuses to die
rm -f "$W/module/paused"
cat > "$W/bin/pkill" <<'EOF'
#!/usr/bin/env sh
exit 0     # pretends to kill, relay keeps running
EOF
printf '777\n' > "$W/running"
out=$(sh "$W/module/webui.sh" pause 2>&1); rc=$?
expect "pause refuses when relay survives" "1" "$rc"
echo "$out" | grep -q "^error=" && ok "pause reports an error when the relay survives" || bad "no error: $out"
[ -f "$W/module/paused" ] && bad "set paused even though the relay survived" || ok "no paused marker on failure"

# resume
cat > "$W/bin/pkill" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
rm -f "$W/running"
out=$(sh "$W/module/webui.sh" resume 2>&1); rc=$?
expect "resume exit 0" "0" "$rc"
echo "$out" | grep -q "^pid=12345$" && ok "resume starts the relay and reports its pid" || bad "resume output: $out"
[ -f "$W/action_called" ] && ok "resume goes through action.sh" || bad "action.sh not called"
[ -f "$W/module/paused" ] && bad "paused marker not cleared" || ok "paused marker cleared"

# exportlog
out=$(sh "$W/module/webui.sh" exportlog 2>&1); rc=$?
expect "exportlog exit 0" "0" "$rc"
echo "$out" | grep -q "^ok=3$" && ok "exportlog copies 3 files" || bad "exportlog output: $out"
expect "exported current log"  "hello log" "$(cat "$W/sdcard/Download/gxr-alvr-log.txt" 2>/dev/null)"
expect "exported previous log" "older"     "$(cat "$W/sdcard/Download/gxr-alvr-log-previous.txt" 2>/dev/null)"
expect "exported install log"  "install"   "$(cat "$W/sdcard/Download/gxr-alvr-install-log.txt" 2>/dev/null)"

# status carries paused=
printf '1\n' > "$W/module/paused"
cat > "$W/bin/ip" <<'EOF'
#!/usr/bin/env sh
echo "    inet 192.168.0.5/24 brd 192.168.0.255 scope global wlan0"
EOF
chmod +x "$W/bin/ip"
out=$(sh "$W/module/webui.sh" status 2>&1)
echo "$out" | grep -q "^paused=1$" && ok "status reports paused=1" || bad "status output: $out"

# ---- dilation range lock/unlock/reset (v1.3.10) ----
rm -f "$W/module/paused"

# a paused module must not be started by a dilation tap
printf '1\n' > "$W/module/paused"
out=$(sh "$W/module/webui.sh" dilcal lock 2>&1); rc=$?
expect "dilcal refuses while paused" "1" "$rc"
echo "$out" | grep -q "paused" && ok "dilcal explains the pause" || bad "no pause error: $out"
rm -f "$W/module/paused"

printf '3.100\n' > "$W/module/dilmin"
printf '4.700\n' > "$W/module/dilmax"
rm -f "$W/module/dillock" "$W/action_called"
out=$(sh "$W/module/webui.sh" dilcal lock 2>&1); rc=$?
expect "dilcal lock exit 0" "0" "$rc"
echo "$out" | grep -q "^dillock=1$" && ok "dilcal lock reports dillock=1" || bad "dilcal lock output: $out"
[ -f "$W/module/dillock" ] && ok "dillock marker written" || bad "dillock marker missing"
[ -f "$W/action_called" ] && ok "dilcal restarts the relay" || bad "dilcal did not restart the relay"
echo "$out" | grep -q "^dilmin=3.100$" && ok "dilcal reports the frozen values" || bad "dilmin missing: $out"

# an explicit --dil-min/--dil-max pair in devopts outranks the files
printf -- '--dil-min 3.1\n--dil-max 4.7\n' > "$W/module/devopts"
out=$(sh "$W/module/webui.sh" dilcal unlock 2>&1); rc=$?
expect "dilcal unlock refuses while --dil-min/max are set" "1" "$rc"
echo "$out" | grep -q "Developer options" && ok "dilcal names the conflicting option" || bad "no conflict error: $out"
rm -f "$W/module/devopts"

out=$(sh "$W/module/webui.sh" dilcal unlock 2>&1); rc=$?
expect "dilcal unlock exit 0" "0" "$rc"
echo "$out" | grep -q "^dillock=0$" && ok "dilcal unlock reports dillock=0" || bad "dilcal unlock output: $out"
[ -f "$W/module/dillock" ] && bad "dillock survived unlock" || ok "dillock marker removed"

rm -f "$W/module/dilmin"
out=$(sh "$W/module/webui.sh" dilcal lock 2>&1); rc=$?
expect "dilcal lock refuses without values" "1" "$rc"
echo "$out" | grep -q "^error=" && ok "dilcal lock explains the refusal" || bad "no error: $out"

printf '3.100\n' > "$W/module/dilmin"
printf '1\n' > "$W/module/dillock"
# Reset must delete AFTER stopping the relay: the relay flushes its range on a
# clean exit, so delete-then-kill would be undone by that flush. The stub below
# emulates the flush, so a wrong order leaves the files behind and fails here.
cat > "$W/bin/pkill" <<EOF
#!/usr/bin/env sh
case "\$1" in
  -x) printf '3.100\n' > "$W/module/dilmin"; printf '4.700\n' > "$W/module/dilmax"; rm -f "$W/running" ;;
esac
exit 0
EOF
out=$(sh "$W/module/webui.sh" dilcal reset 2>&1); rc=$?
expect "dilcal reset exit 0" "0" "$rc"
[ -f "$W/module/dilmin" ] && bad "reset left dilmin (deleted before the relay stopped)" || ok "reset removes dilmin"
[ -f "$W/module/dilmax" ] && bad "reset left dilmax" || ok "reset removes dilmax"
[ -f "$W/module/dillock" ] && bad "reset left dillock" || ok "reset removes dillock"

# writing a range by hand: no calibration, just two numbers
rm -f "$W/module/dilmin" "$W/module/dilmax" "$W/module/dillock" "$W/action_called"
out=$(sh "$W/module/webui.sh" dilcal set 3.2 4.6 2>&1); rc=$?
expect "dilcal set exit 0" "0" "$rc"
expect "set writes dilmin" "3.200" "$(cat "$W/module/dilmin" 2>/dev/null)"
expect "set writes dilmax" "4.600" "$(cat "$W/module/dilmax" 2>/dev/null)"
[ -f "$W/module/dillock" ] && ok "set locks the range" || bad "set did not lock the range"
[ -f "$W/action_called" ] && ok "set restarts the relay" || bad "set did not restart the relay"

out=$(sh "$W/module/webui.sh" dilcal set 4.6 3.2 2>&1); rc=$?
expect "set refuses inverted values" "1" "$rc"
expect "inverted set left dilmin alone" "3.200" "$(cat "$W/module/dilmin" 2>/dev/null)"

out=$(sh "$W/module/webui.sh" dilcal set abc 4 2>&1); rc=$?
expect "set refuses non-numeric input" "1" "$rc"
echo "$out" | grep -q "^error=" && ok "set explains non-numeric input" || bad "no error: $out"

rm -f "$W/module/dillock"
printf '3.400\n' > "$W/module/dilmin"
printf '4.900\n' > "$W/module/dilmax"
out=$(sh "$W/module/webui.sh" status 2>&1)
echo "$out" | grep -q "^dilmin=3.400$" && ok "status reports dilmin" || bad "status missing dilmin: $out"
echo "$out" | grep -q "^dilmax=4.900$" && ok "status reports dilmax" || bad "status missing dilmax: $out"
echo "$out" | grep -q "^dillock=0$" && ok "status reports dillock" || bad "status missing dillock: $out"

# ------------------------------------------------- gxr_alvr.c source guards
echo "== gxr_alvr.c =="
SRC="$MOD/../../headset/gxr_alvr.c"
if [ ! -f "$SRC" ]; then
  bad "sender source not found at $SRC"
else
  CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
  if [ -n "$CC_BIN" ]; then
    if "$CC_BIN" -O2 -Wall -Wextra -o "$ROOT/gxr_alvr-host" "$SRC" -lm 2>"$ROOT/cc.log"; then
      ok "sender compiles (-O2 -Wall -Wextra)"
    else
      bad "sender failed to compile"
      sed 's/^/    /' "$ROOT/cc.log"
    fi
    if [ -x "$ROOT/gxr_alvr-host" ]; then
      expect "built binary reports the module.prop version" \
        "$(sed -n 's/^version=v//p' "$MOD/module.prop")" \
        "$("$ROOT/gxr_alvr-host" --version | awk '{print $2}')"
    fi
    if "$CC_BIN" -O2 -Wall -Wextra -o "$ROOT/relay_selftest" \
        "$(cd "$(dirname "$SELF")" && pwd)/relay_selftest.c" -lm 2>"$ROOT/cc2.log"; then
      ok "relay selftest harness compiles"
      diag=$("$ROOT/relay_selftest" 2>"$ROOT/selftest.err")
      rc_self=$?
      expect "relay selftest passes" "0" "$rc_self"
      printf '%s\n' "$diag" | grep -q '^selftest_bad=0$' && ok "selftest reports zero failures" || bad "selftest failures: $diag"
      dline=$("$ROOT/relay_selftest" 2>&1 >/dev/null | grep '^gxr_alvr: process:')
      expect "context diagnostic is one line" "1" "$(printf '%s\n' "$dline" | wc -l | tr -d ' ')"
      case "$dline" in
        "gxr_alvr: process: pid="*) ok "context diagnostic names pid/ppid/parent" ;;
        *) bad "context diagnostic shape: $dline" ;;
      esac
      printf '%s' "$dline" | grep -q ' cgroup=' && ok "context diagnostic includes cgroup" || bad "no cgroup field"
      printf '%s' "$dline" | grep -q ' oom_score_adj=' && ok "context diagnostic includes oom_score_adj" || bad "no oom_score_adj field"
      dlen=$(printf '%s' "$dline" | wc -c | tr -d ' ')
      if [ "$dlen" -le 300 ]; then ok "context diagnostic is bounded ($dlen bytes)"; else bad "context diagnostic is $dlen bytes"; fi
      printf '%s' "$dline" | grep -qiE 'token|secret|password|serial' \
        && bad "context diagnostic looks like it could leak a secret" \
        || ok "context diagnostic carries no secret-shaped fields"
      grep -q 'not a slow loop; resuming' "$ROOT/selftest.err" \
        && ok "watchdog long-gap message says it resumed" || bad "watchdog long-gap message missing"
      grep -q 'maintenance has not returned' "$ROOT/selftest.err" \
        && ok "maintenance overrun is reported" || bad "maintenance overrun message missing"
      grep -q 'or the process was not scheduled during it' "$ROOT/selftest.err" \
        && ok "maintenance overrun allows for not being scheduled" || bad "maintenance wording is incomplete"
      grep -qi 'frozen' "$ROOT/selftest.err" \
        && bad "watchdog message claims a freeze" || ok "watchdog message makes no freeze claim"
    else
      bad "relay selftest harness failed to compile"
      sed 's/^/    /' "$ROOT/cc2.log"
    fi
  else
    echo "  SKIP  host C build (no cc/gcc on PATH)"
  fi

  # Health-check safety: a read failure must be UNKNOWN, the expected set is the
  # one this run actually armed, and a device-wide clear (which also drops other
  # tools' probes) needs repeated confirmation plus a rate limit.
  HC=$(sed -n '/^static int health_check/,/^}/p' "$SRC")
  if [ -z "$HC" ]; then
    bad "could not locate health_check"
  else
    printf '%s' "$HC" | grep -q 'if (snap < 0)' && ok "health check separates read failure from missing probes" || bad "no unknown-state branch"
    printf '%s' "$HC" | grep -q 'g_hcBaseMask & ~mask' && ok "health check requires only probes this run armed" || bad "no baseline probe set"
    printf '%s' "$HC" | grep -q 'HC_CONFIRM_MISS' && ok "re-arm requires repeated confirmation" || bad "no confirmation requirement"
    printf '%s' "$HC" | grep -q 'rearm_allowed' && ok "re-arm pacing uses the testable floor helper" || bad "re-arm does not use the floor helper"
    grep -q 'REARM_MIN_MS' "$SRC" && ok "re-arm floor is defined" || bad "no re-arm floor"
    grep -q 'REARM_MAX_MS' "$SRC" && ok "re-arm backoff is capped" || bad "no capped re-arm backoff"
    printf '%s' "$HC" | grep -q 'REARM_MAX_FAILS' && ok "re-arm attempts are bounded" || bad "no bound on failed re-arms"
    printf '%s' "$HC" | grep -q 'HC_REARM_GAVEUP' && ok "giving up is reported to the verdict" || bad "give-up state is not reported"
    printf '%s' "$HC" | grep -q 'verified\|could not be verified\|did not stick' && ok "health log reports verification" || bad "health log does not report verification"
  fi
  STARTUP=$(sed -n '/^int main/,/while (!g_stop)/p' "$SRC")
  printf '%s' "$STARTUP" | grep -q 'g_lastRearmMs = now_ms()' && ok "startup starts the re-arm floor clock" || bad "startup does not set the re-arm floor"
  printf '%s' "$STARTUP" | grep -q 'probe_mask_from_arms' && ok "startup baseline comes from arm results" || bad "startup baseline does not use arm results"
  if printf '%s' "$STARTUP" | grep -q 'g_hcBaseMask |= smask'; then
    bad "startup baseline is still taken from the snapshot"
  else
    ok "startup snapshot is observational only"
  fi
  PS=$(sed -n '/^static int probe_snapshot/,/^}/p' "$SRC")
  printf '%s' "$PS" | grep -q 'errno == EINTR' && ok "probe read retries EINTR" || bad "probe read does not retry EINTR"
  printf '%s' "$PS" | grep -q 'return -1' && ok "probe read can report unknown" || bad "probe read cannot report unknown"
  printf '%s' "$PS" | grep -q 'PROBE_CARRY' && ok "probe read is incremental across chunks" || bad "probe read is not incremental"
  printf '%s' "$PS" | grep -q 'HC_READ_MAX' && bad "probe read still has an oversized-buffer case" || ok "probe read has no oversized-buffer case"

  # The heartbeat runs outside the g_maint window, so it must never reach into
  # tracefs: a uprobe_events seq_file read serialises on the global event_mutex.
  HB=$(sed -n '/if (tnow >= nextHb)/,/^        }$/p' "$SRC")
  if [ -z "$HB" ]; then
    bad "could not locate the heartbeat block"
  elif printf '%s' "$HB" | grep -q 'hb t=' && \
       ! printf '%s' "$HB" | grep -qE 'event_present|tracing_enabled|probe_snapshot|open\('; then
    ok "heartbeat uses the cached health snapshot only"
  else
    bad "heartbeat touches tracefs directly"
  fi

  # A long gap must be reported as "not scheduled or blocked" and must resume,
  # without asserting a freeze that the log cannot prove.
  ALARM=$(sed -n '/^static void on_alarm/,/^}/p' "$SRC")
  if [ -z "$ALARM" ]; then
    bad "could not locate on_alarm"
  else
    printf '%s' "$ALARM" | grep -q 'LONG_GAP_MS' && ok "watchdog distinguishes a long gap" || bad "no long-gap branch"
    printf '%s' "$ALARM" | grep -q 'resuming' && ok "watchdog resumes after a long gap" || bad "long gap does not resume"
    printf '%s' "$ALARM" | grep -q '_exit(1)' && ok "watchdog still exits on a real loop stall" || bad "ordinary stall no longer exits"
    printf '%s' "$ALARM" | grep -q 'MAINT_WARN_MS' && ok "watchdog reports overrunning maintenance" || bad "no maintenance overrun report"
    printf '%s' "$ALARM" | grep -q 'g_printReset = 1' && ok "watchdog defers the log-marker reset" || bad "no deferred log-marker reset"
    if printf '%s' "$ALARM" | grep -q 'g_printStartMs'; then
      bad "watchdog handler writes the 64-bit log marker"
    else
      ok "watchdog handler leaves the log marker to the main loop"
    fi
    if printf '%s' "$ALARM" | grep -qi 'frozen'; then
      bad "watchdog message claims a freeze"
    else
      ok "watchdog message makes no freeze claim"
    fi
  fi
fi

# ------------------------------------- packaged/tracked sender binary version
# Independent of any host compiler and of the source tree: the binary that the
# module actually ships must be the new build, i.e. it must embed the version
# from module.prop and the new log strings, and must not still carry the old
# watchdog text.
echo "== module binary =="
BIN="$MOD/gxr_alvr"
MPVER=$(sed -n 's/^version=v//p' "$MOD/module.prop")
if [ ! -f "$BIN" ]; then
  bad "module binary missing: $BIN"
else
  if LC_ALL=C grep -aq "$MPVER" "$BIN"; then
    ok "tracked module binary embeds version $MPVER"
  else
    bad "tracked module binary does not embed $MPVER (stale build?)"
  fi
  for marker in "gxr_alvr: process:" "was not scheduled or was blocked" \
                "could not read uprobe_events" "did not stick" \
                "a required probe had disappeared" "automatic re-arm disabled"; do
    if LC_ALL=C grep -aq "$marker" "$BIN"; then
      ok "module binary contains new code marker: $marker"
    else
      bad "module binary lacks new code marker: $marker (stale build?)"
    fi
  done
  if LC_ALL=C grep -aq "main loop stalled" "$BIN"; then
    bad "module binary still contains the old watchdog message"
  else
    ok "module binary has no old watchdog message"
  fi
  if [ ! -f "$MOD/../../headset/gxr_alvr" ]; then
    echo "  SKIP  headset/gxr_alvr absent (it is an ignored build output)"
  elif cmp -s "$BIN" "$MOD/../../headset/gxr_alvr"; then
    ok "module binary and headset/gxr_alvr are identical"
  else
    bad "module binary differs from headset/gxr_alvr"
  fi
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" = "0" ]
