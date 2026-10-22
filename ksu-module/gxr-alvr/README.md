# `gxr-alvr` - Galaxy XR face-tracking relay (KernelSU module)

Ships the headset-side sender `gxr_alvr` and starts it as root at boot. It reads
the Galaxy XR perception host through read-only ftrace uprobes and streams the
full face/eye parameter set to the PC on **UDP 41463**, for the VRCFaceTracking
module [`compdoge/VRCFT-ALVR-UE`](https://github.com/compdoge/VRCFT-ALVR-UE).

> **ALVR is NOT required.** Neither this module nor the PC side needs the ALVR
> streamer, the ALVR app, or any ALVR setup. "ALVR" is in the module id only
> because we reuse ALVR's `UniExpr` packet *format*.

**Install:** the zip goes into the KernelSU Manager, then **reboot** (installing
alone does not restart the relay). The PC-side module, the full walkthrough and
the troubleshooting notes - nothing arrives, auto-connect flaky, Wi-Fi
trackers/streaming stutter - are in the
[repo README](https://github.com/compdoge/gxr-root-ft#readme).

The relay reports its own build in the `armed` log line, so after installing a
build check that it matches the module version shown by the Manager (for example
`v1.3.12 armed`). A mismatch means the zip carried an older `gxr_alvr` binary.

The rest of this file is reference.


## Option files

Every setting is an optional file in the module directory. All of them are
**preserved across module updates**. The WebUI writes them for you; the Manager
**Action** button (or a reboot) applies a change.

| file | purpose |
|---|---|
| `pc` | PC IPv4 address, or a comma-separated list of them. Absent = auto/broadcast. |
| `port` | UDP port, default `41463`. |
| `mirror` | extra port: also send a copy to `<target>:<port>` (for a monitor tool). |
| `tongue` | `0` disables the extra `TongueRoll` parameter. |
| `verbose` | enables the fast tuning log (see Logs). |
| `devopts` | the WebUI's Developer-options flags, one `--flag value` per line. A **pure data file**: values are restricted to `A-Za-z0-9 . _ , : / + - =`, so nothing can escape into the shell. |
| `dev` | opt-in dev override: prefer a binary at `/data/local/tmp/gxr_alvr` (see Dev mode). |
| `dilmin`, `dilmax` | the learned pupil-dilation range, in our internal scale. Written by the relay as it learns, read back as the starting range on the next start. See **The dilation range**. |
| `dillock` | marker: freezes `dilmin`/`dilmax`. Written by the WebUI **Lock** button, removed by **Unlock**. |
| `paused` | marker: written by the WebUI **Pause** button, cleared by **Resume**. A reboot starts the relay regardless. |

By hand (root):

```sh
echo 192.168.1.50 > /data/adb/modules/gxr-alvr/pc
echo 41463        > /data/adb/modules/gxr-alvr/port   # optional
```

## Action button

The Manager **Action** button runs `action.sh`: it stops the **supervisor** and
the relay, then starts a fresh supervised relay immediately, with no reboot. Use
it after changing option files or after a dev binary push. **A module update does
not restart the relay by itself** - tap **Action** (or reboot) after installing a
new version. The WebUI's *Save & restart* does that for you.

## Developer options (WebUI)

The WebUI's **Developer options** card exposes the sender's tuning knobs, each
with a one-line description - the datagram rate (`--tx-hz`), the wink fold
(`--wink-gap`, `--wink-ms`), the mirror port, TongueRoll gain, the dilation keys
(`--pupil-dilation-gain`, `--pupil-smooth-ms`, `--pupil-min-conf`), the explicit
dilation range (`--dil-min`, `--dil-max`) and the gaze
keys. The gaze keys decide when an eye's
direction is *trustworthy*: a pitch-guarded blink test plus a pupil test relative
to that eye's own recent size (`--gaze-lid-low`, `--gaze-pupil-ratio`), a
smoothing-only band for a narrowed lid that the pupil test cannot see
(`--gaze-soft-open`, `--gaze-soft-fmin`), and the base filter speed
(`--gaze-smooth-fmin`).

A nested **Advanced - firmware probes** section holds the firmware-specific uprobe
offsets and plugin paths. They exist so the module can track a firmware change
without a rebuild, but a wrong value stops face/eye tracking entirely - leave them
alone unless you know your firmware differs.

### The wink fold (`--wink-gap`)

The device reports `eyes_closed` per eye, but it folds the lid tightener in
afterwards in its own wink postprocessor - and the module reads the value before
that. Measured on this firmware, a deliberate wink therefore tops out around 0.6
(openness ~0.4) while a blink reaches 1.0, so a wink used to leave the avatar's
eyelid partly open.

The sender restores it: when one eye is clearly closing while the other stays open
(that gap is the `--wink-gap`, default 0.35), it drives that eyelid shut over
`--wink-ms` (default 200). Both eyes closing (a blink) or both narrowing (a
squint) show no left/right gap, so nothing is folded for them - which is what makes
this different from the old unconditional fold that used to saturate squints.
`--wink-gap 0` disables the fold.

### The dilation range

VRCFT turns the pupil diameter into the 0..1 `PupilDilation` value with
`(pupil - min) / (max - min)`, where `min`/`max` are the window this module sends
in every frame - not a fixed physiological range. That window therefore decides
how much of the avatar's dilation range your eyes actually use: a wide fixed band
(a real pupil only moves about 3-5 mm) looks weak, while a window fitted to your
own eyes uses most of the range.

The relay learns the window from frames it can trust (both eyes reading, both
lids clearly open). Since v1.3.11 it seeds from the median of the first 8 clean
frames instead of one frame, remembers the window across restarts
(`dilmin`/`dilmax`), only commits a new extreme when both raw readings still match
it, and slowly heals an extreme that has not been approached for ten minutes (and
only while your recent pupil swing is at least 0.5 mm, so sitting still in steady
light cannot collapse the range).

Once the range has settled, **Lock** freezes it - that is the recommended state,
because it stops a stray reading or a lighting change from squeezing the range
mid-session. **Reset** forgets it and learns again from scratch (it stops the relay
first, so the range cannot be written back on the way out). A locked window that is
narrower than your pupils in very bright or very dark light will leave the avatar's
pupils at 0 or 1 at the extremes: that is the honest behaviour of a fixed range, so
Unlock or Reset if you want it to adapt again.

The numbers are our internal scale, not true millimetres (the scale cancels inside
VRCFT because the window is sent along with the diameter). They are the *learned
envelope*: the window VRCFT actually receives is 1 / `--pupil-dilation-gain` wider
(33% wider at the default 0.75), so copying the shown numbers reproduces the
current behaviour rather than narrowing it. Copy them from the WebUI or from
`min=`/`max=` in the verbose log.

To skip calibration entirely, type a min and max into the Dilation card and press
**Use these values**: it writes both files, locks the range and restarts the relay.
The `--dil-min` / `--dil-max` developer options do the same thing from the command
line; either way the explicit pair outranks the learned files (Unlock/Reset refuse
to pretend otherwise while it is set).

A field left at its default is omitted, so future default changes still reach you;
**Reset to defaults** clears the file. PC IP, UDP port, TongueRoll and Verbose have
their own controls in the **Connection** card above.

## Pause / Resume / Export logs (WebUI)

The page refreshes itself every 10 seconds while it is visible and immediately when
you return to it, so the status, the log tail and the dilation range stay current
without a reload. It pauses while you are typing in a field and while an action is
running.

The status card has three buttons:

- **Pause** stops the supervisor and the relay, and the relay disables its probes
  on the way out, so a paused module is genuinely not tracing anything. No reboot
  and no module swap - which makes it the honest way to answer "is this module
  costing me frames or heat": run the same session paused and running, watching
  the headset's own thermals and FPS.
- **Resume** starts it again.
- **Export logs** copies the current log, the previous run and the install log to
  `/sdcard/Download` (`gxr-alvr-log.txt`, `gxr-alvr-log-previous.txt`,
  `gxr-alvr-install-log.txt`), overwriting the older copies rather than piling up
  files.

A pause lasts until **Resume** or a reboot (a reboot always starts the relay).

## Monitor / A-B (optional)

To watch the values on the PC while VRCFT keeps 41463, create a `mirror` file with
the extra port - the relay then also sends a copy to `<target>:<port>`:

```sh
echo 41464 > /data/adb/modules/gxr-alvr/mirror
```

Set `tongue` to `0` to disable the extra `TongueRoll` parameter (A-B test). Both
are read at start - tap the **Action** button after changing them.

## Dev mode (opt-in)

To iterate on the sender without reinstalling the module, create an empty `dev`
file and push a binary:

```sh
touch /data/adb/modules/gxr-alvr/dev
adb push gxr_alvr /data/local/tmp/gxr_alvr && adb shell chmod 755 /data/local/tmp/gxr_alvr
```

Now `service.sh`/`action.sh` prefer `/data/local/tmp/gxr_alvr`. Delete `dev` to
return to the bundled binary. (The dev override is opt-in because a stale
`/data/local/tmp/gxr_alvr` silently shadowing the module binary is a footgun for
shipped users.)

## Files

| file | purpose |
|---|---|
| `gxr_alvr` | the sender (built from `headset/gxr_alvr.c`) |
| `service.sh` | boot / late-load start |
| `action.sh` | Manager Action button = restart now |
| `supervise.sh` | reads the option files and runs the relay under a respawn supervisor; called by both of the above |
| `webui.sh` | helper for the Manager WebUI page (status / set / setdev / dilcal / pause / resume / exportlog / test) |
| `webroot/index.html` | the Manager WebUI page (PC IP, status, dilation range, Pause/Resume, log export, log tail, Developer options) |
| `customize.sh` | installer permissions + ui_print |
| `uninstall.sh` | stop the relay on uninstall |
| `sepolicy.rule` | allow the KernelSU root domain to use tracefs (Enforcing) |
| `module.prop` | module metadata |
| `pc`, `port`, `mirror`, `tongue`, `verbose`, `devopts`, `dev` | optional overrides (not shipped - see Option files) |

## Logs

`/data/local/tmp/gxr_alvr.log` -- a **fresh file on every start** (the previous
run is kept as `gxr_alvr.log.1`). The relay also logs `armed ...` / `auto target
...` at startup, and a **heartbeat** every 15 s written from its main loop, so a
stall is visible even when nothing is arriving:

```
gxr_alvr: hb t=<ms> ev=<probe events> tx=<datagrams> cmp=<frames computed> idle=<ms since last event> probes=<n>/5 base=<n>/5 on=<1|0> quiet=<n> verbose=<1|0> gaps=<n> hc=<ms>
```

`cmp` counts recomputes of the outgoing frame. Since v1.3.11 that should track
`tx` (about 60/s at the default rate) rather than `ev`; before v1.3.11 it
followed the ~15 Hz expression events.

`probes=` and `on=` are the **last health-check snapshot**, not a live read, and
`hc=` is that snapshot's age in ms (normally at most 3000). Reading the tracefs
event list takes a kernel lock that probe creation anywhere on the device also
needs, so the heartbeat must not do it: the 3 s health check samples it inside
the relay's maintenance guard (one streamed scan, plus one verification scan after
a re-arm), and the heartbeat reports that cached result (seeded once at startup,
before the first beat). `-1` means **unknown** (the read failed or has not
happened yet) - never "healthy" and never "gone". `gaps=` counts long no-progress
gaps the relay resumed from (see the watchdog note below).

`base=` is the probe set **this run's arm calls actually succeeded on at
startup** (plus anything a later verified re-arm restored), so a start where an
optional probe could not be armed legitimately reports `probes=4/5 base=4/5` for
its whole life. The startup event-list read is only an observational cache for
the heartbeat and never decides what is required, so a failed startup read does
not shrink the baseline. `pten` is mandatory: if its uprobe cannot be armed the
relay exits `rc=3` instead of running without pupil data. The other four are
optional; one that failed at startup is only retried by an explicit restart
(Manager **Action**, WebUI **Resume**, or a reboot), never by clearing the
device-wide probe set in a loop. A `probes=` below `base=` means a probe that was
armed has disappeared; that is recovered as described under *quiet episodes*
below.

The first lines of a run also record **where the process came from**:

```
gxr_alvr: process: pid=... ppid=... parent=sh chain=sh<sh<ksud<init cgroup=0::/... oom_score_adj=0
```

`chain` is the parent chain (up to four ancestors, nearest first); the example
is a boot start, where a Manager start instead shows the Manager app in place of
`ksud`. `cgroup` is `/proc/self/cgroup`. A start from the Manager **Action**
button or the WebUI normally shows the Manager app in that chain and an app
cgroup; a boot start does not. Only those kernel identity fields are logged - no
environment, no argv - the values are length-capped and stripped of control
characters, and a failed read prints `unknown`.

`idle` climbing while `ev` stands still means the device is not feeding us;
`ev` still climbing but `tx` frozen would mean the transmit side is wedged; no
new heartbeat at all means the process is gone. `ev` counts only this relay's own
probe events, so other tracefs users cannot make the link look alive.

A quiet device is the **normal** state: with no app asking for tracking, nothing
calls the probed functions. Silence therefore proves nothing by itself, so when no
event has arrived for 3 s the relay logs one
`no probe events for ... quiet episode #n` line per episode and quotes the tracefs
verdict it actually established: healthy (idle, not a fault), re-armed, a re-arm
that did not restore the set, a `tracing_on` problem, a required probe missing
but not yet confirmed, automatic re-arming stopped after repeated failures
(restart to retry), or state unverifiable. Clearing `uprobe_events`
drops **every** uprobe on the device, including a capture tool's, so the relay
only does that after three consecutive successful health-check reads show a probe
that it had armed missing, with a 30 s floor counted from the initial tracefs
cleanup (so even a fault visible at the first check waits) that doubles while
re-arms keep failing (capped at 10 minutes) instead of churning. After **five**
failed re-arms it stops trying and logs that a restart is needed to retry. A
failed read is reported as unknown; it is never treated as evidence that the
probes are gone, and re-arming is deliberately not triggered by idleness: it
could not fix the one case it cannot see (a foreign `trace_pipe` consumer)
anyway.

If the heartbeat itself stops, the sender's own 5 s watchdog decides what the gap
means. A gap of 5-15 s is treated as a real loop stall: it logs one line and exits
so the supervisor restarts the relay. A gap longer than 15 s (three watchdog
periods) is treated differently: the timer handler only runs once the process is
back in user mode, so a gap that long means the process was not running at all -
stopped, frozen by a platform policy, or parked in the kernel - and the log cannot
tell those apart. The relay then logs one

```
gxr_alvr: watchdog: no main-loop progress for <ms> ms (over 15000 ms); the process was not scheduled or was blocked, not a slow loop; resuming
```

line and keeps running with its tracefs state and learned dilation range intact
instead of exiting; a genuine userspace spin still trips the 5 s branch within one
watchdog period of that reset. The message deliberately does not name a cause. The
line is also counted in the next heartbeat as `gaps=<n>`.

The watchdog's own setup is reported: if `sigaction`/`setitimer` fails or SIGALRM
cannot be unblocked, startup logs `watchdog NOT armed` instead of running without
one silently. Tracefs maintenance is exempt from the progress check (killing the
relay in the middle of a tracefs operation is how a kill/restart loop starts), but
it is not allowed to be silent forever: if maintenance has not returned after
15 s, one `tracefs maintenance has not returned for <ms> ms (or the process was
not scheduled during it); not exiting ...` line is written when the process next
executes user code (a syscall blocked in the kernel reports it on return, not
while it is blocked). That is a report, not a diagnosis.

`verbose` adds the tuning trace (~20 Hz gaze, 4 Hz pupil). Its lines carry what a
field capture needs to explain an eye: `open=` is the EMITTED openness (so the
wink fold is visible), `closed=` the raw sensor value and `wb=` the wink-fold
boost applied to it, `held=` the gaze trust gate, `pu=` the pupil size relative
to that eye's own baseline, and `lk=1` marks a locked dilation range (`min=` and
`max=` are the learned envelope). The trace is batch-written and flushed at least on
every heartbeat; past 4 MB in a single run, verbose switches itself off and the
heartbeat slows to every 5 minutes, so a long run cannot grow the log without
bound. If single log writes start taking more than a second - a busy filesystem -
verbose turns itself off rather than stall the sensor loop, and says so in the log.

## Load (what it costs the headset)

The module is read-only: it hooks 5 existing vendor functions with uprobes and
parses the events they emit. In a real session (Virtual Desktop + VRChat) those 5
probes together fire about **330 times a second** - roughly 4.6 per frame at
72 Hz - and the relay parses them and sends ~50-60 datagrams/s. That is the whole
cost, and it does not depend on how many PC-side modules read the stream.

Since v1.3.11 the relay recomputes the outgoing frame every 16 ms instead of once
per expression event, so at the default 60 Hz transmit rate gaze and pupil reach
the PC at their own ~57 Hz / ~42 Hz. A slower `--tx-hz` sends fewer datagrams, but
each one is still computed within 16 ms of the data it carries. The expression
values themselves still change only at the vendor's ~15 Hz - that limit is
upstream, not in the relay.

Idle is deliberately much cheaper than active: once no probe event has arrived for
1 s the relay drops to a 10 Hz loop and a 10 Hz keepalive (still sending a relaxed
neutral frame, so the PC side sees no difference) and returns to the full rate the
moment real events arrive. Before v1.3.8 it polled and transmitted at the full
rate around the clock, tracking or not.

The trace ring buffer is **1024 KB per CPU** (6 MB on this 6-core SoC). It used to
be 16384 KB per CPU - about 96 MB of unreclaimable kernel memory held for the whole
session - which was sized for an old blocking-read stall that no longer exists.

## Notes

- Uprobe offsets are **firmware-specific** (firmware `I610UEU2AZF3`); the sender
  fails soft per probe if the firmware changes.
- The relay refuses to start a second copy (flock at
  `/data/local/tmp/gxr_alvr.lock`) and self-heals if tracefs is cleared under it.
- The relay never blocks on I/O: `trace_pipe` is read non-blocking, and the UDP
  socket is non-blocking too, so a full send buffer or a Wi-Fi hiccup drops a
  datagram instead of parking the loop. A completed log write also counts as loop
  progress, so a filesystem stall is not mistaken for a wedged relay - restarting
  would just write the same log again and make the tracking gap longer.
- `service.sh`/`action.sh` run the relay under `supervise.sh`, which restarts it
  if it exits (a crash, or the sender's own watchdog). So `pkill -x gxr_alvr` on
  its own no longer stops the relay -- it comes straight back. Stop the
  supervisor first, or just use the Manager's **Action** button. A relay that
  keeps failing to start is retried with a growing delay (2 s up to 60 s).
- Two exits are special. `rc=137` (SIGKILL from outside the module - usually the
  low-memory killer, or a vendor/thermal policy shedding background work) is not
  retried: that kill is the system's decision about this process, and restarting
  means rebuilding every uprobe and asking for the ring buffer again, i.e. putting
  back the load it was shedding. The supervisor logs it and stops instead; start
  the relay again from the Manager **Action** button or the WebUI **Resume**.
  `rc=5` (another relay holds the single-instance lock) is retried **3 times,
  2 s apart**: the holder may be an instance that is still finishing its own
  SIGTERM exit (the relay disarms tracefs on the way out). Those retries do
  **not** recover a stopped/blocked holder. If the lock is still held after them,
  the supervisor logs the holder's pid and stops rather than fighting it: the
  holder may be the healthy relay that won the start, or one that is stuck, and
  the start path cannot tell them apart. The log line says so - it is never a
  silent stop - and Action or Resume starts a fresh attempt later.
- **App lifecycle:** a start from the Manager **Action** button or the WebUI runs
  in a process tree that inherited the Manager's app context; a boot start does
  not. The `process:` log line records the chain, cgroup and `oom_score_adj` the
  run actually got, so an exported log answers which one it was. If the link must
  survive the Manager being backgrounded, prefer the boot start.
- Wire format is fixed: `"UniExpr\0"` + 88 `float32` UE weights + an 11-float eye
  tail (99 floats, 396 B payload, 404 B datagram). Do not change it without
  updating the PC-side module.
