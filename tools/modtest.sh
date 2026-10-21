#!/usr/bin/env bash
# Offline harness for the module scripts. No device involved.
#   - supervise.sh: rc=137 must be terminal (no respawn); other rcs must retry.
#   - webui.sh pause/resume/exportlog/dilcal logic, with the Android paths sandboxed.
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

echo
echo "passed=$pass failed=$fail"
[ "$fail" = "0" ]
