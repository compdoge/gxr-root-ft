# gxr-root-ft

Galaxy XR -> PC **full face/eye tracking** for VRChat. A rooted headset streams its
complete face/eye parameter set to a PC running **VRCFaceTracking**, so your
avatar's face and eyes follow yours.

This repo is the **headset side** - the sender and the KernelSU module that runs
it at boot. The PC side is a separate VRCFaceTracking module (installed in step 2
below).

> ### ALVR is NOT required
> You do **not** need the ALVR streamer, the ALVR app, or any ALVR setup.
> "ALVR" appears in these names only because we reuse ALVR's `UniExpr` packet
> *format*. No ALVR software is involved.

## What you need

- **Headset:** Galaxy XR (`SM-I610`) with **root** (KernelSU or DFRoot) and the
  **KernelSU Manager** installed.
- **PC:** [VRCFaceTracking](https://github.com/benaclejames/VRCFaceTracking)
  installed and working.
- Headset and PC on the **same Wi-Fi / LAN**.

No ALVR. No adb. No terminal.


## Install (normal user)

Two installs, one per machine. Nothing to configure afterwards.

1. **Headset - install the KernelSU module.** Download `gxr-alvr-vX.Y.Z.zip` from
   the **Releases** page, install it in the KernelSU Manager, then **reboot**.
   The sender starts by itself at boot. (Installing on its own does not restart
   the relay - the reboot is what starts it.)
2. **PC - install the VRCFaceTracking module.** Download `ALVRModule.zip` from the
   [VRCFT module's latest release](https://github.com/compdoge/VRCFT-ALVR-UE/releases/latest),
   unzip it, and copy **`ALVRModule.dll`** into
   `%APPDATA%\VRCFaceTracking\CustomLibs` (paste that path into the Explorer
   address bar). Restart VRCFaceTracking and check that **ALVR Module** is listed
   and enabled. It shows up as *ALVR Module* - that is the face-tracking module,
   **not** the ALVR streamer.
3. **Play.** Launch VRChat with face tracking enabled. There is **no PC IP to
   type**: the headset finds the PC by broadcasting.


## If it doesn't work

- **Nothing arrives, or it worked and then stopped.** Check the inbox is open:
  Windows Firewall must allow inbound **UDP 41463** for VRCFaceTracking, and the
  headset and PC must be on the same network.
- **Auto-connect is flaky.** Some access points filter broadcast, and a PC on
  another subnet will never hear it. Pin the PC's IP to switch to unicast ->
  [Set a custom PC IP](#set-a-custom-pc-ip).
- **Wi-Fi trackers or a stream (e.g. Steam Link) stutter.** While it is feeding
  you, the relay sends up to 60 datagrams/s, and to the LAN broadcast address if
  you have not pinned the PC - broadcast is the expensive kind of Wi-Fi traffic.
  Idle it drops to a 10 Hz keepalive, and a pinned PC IP makes the stream unicast.
  If it still stutters, lower the rate in the module's **Developer options ->
  `--tx-hz`**.


## Does it make the headset hotter?

Short answer: it is a small, honest addition, and you can measure it on your own
device.

The module only *reads*. It attaches 5 read-only uprobes to functions the headset
already calls for its own face/eye tracking, and parses the events they emit. In a
real session that is about **330 probe hits a second** in total (roughly 4.6 per
frame at 72 Hz), plus 50-60 small UDP datagrams/s. When nothing is tracking it
idles: a 10 Hz loop and a 10 Hz keepalive. Its trace ring buffer is 6 MB (before
v1.3.8 it was about 96 MB of unreclaimable kernel memory, held for the whole
session).

The Galaxy XR is thermally marginal, and VR streaming already runs it at its
limit - so any extra work can be the straw rather than the bale, and a difference
of a few percent is easy to feel and hard to attribute. If you want to know what
this module costs on *your* headset, use the WebUI: run the same game, in the same
place, with the same stream settings, once with **Pause** and once running, and
compare the headset's temperature and FPS. Pause really does stop it - the relay
disables its probes on the way out - so it is a fair comparison, and it needs no
reboot.


## Set a custom PC IP

**Auto-connect is the default** - with no config the sender broadcasts to the LAN
broadcast address, and the PC module (bound `0.0.0.0:41463`) receives that. Set a
PC explicitly if auto-connect is flaky, if the PC is on another subnet, or to
switch the stream to unicast.

**Easiest: the module's WebUI.** KernelSU Manager -> **Modules** -> *Galaxy XR face
tracking relay* -> tap the **Open** button (or tap the card itself). Enter the PC's
IPv4 address and tap **Save & restart relay**. Leave the field empty and Save to
go back to auto/broadcast. The page also shows live status (target, pid, headset
IP, log tail), a **Test** button that pings the PC from the headset, **Refresh**,
a **Pause** / **Resume** pair that stops and starts face tracking without a
reboot (handy for the comparison below), and **Export logs**, which copies the
current log, the previous run and the install log to `/sdcard/Download`.

**Or by hand (root):**

```sh
echo 192.168.1.50 > /data/adb/modules/gxr-alvr/pc     # as root
echo 41463        > /data/adb/modules/gxr-alvr/port    # optional
# then tap the module's Action button in the KernelSU Manager (or reboot)
```

Delete `pc` to return to auto/broadcast. `port` defaults to `41463`. These option
files (`pc`, `port`, `mirror`, `tongue`, `verbose`, `devopts`, `dev`) are
**preserved across module updates**; the WebUI's `paused` marker is not, so a
reboot always starts the relay.


## Benefits

Using this sender over a generic OpenXR route currently gives you:

1. Eye dilation
2. Individual eye gaze
3. Jaw open not being clamped to >0.5 when tongue out
4. Tongue roll

With hopefully more to come!


## For developers

Everything below is about building and modifying the sender. If you just want to
use it, stop here.

### How it works

The headset runs `gxr_alvr` as **root**. It reads the Galaxy XR perception host
through **read-only ftrace uprobes** - it only *reads*; it never patches or
injects into vendor code, and it carries numeric signals only (no camera imagery).

Repo layout:

- `headset/` - the C sender `gxr_alvr` (+ build script, wire-format doc, tools).
- `ksu-module/gxr-alvr/` - the KernelSU module that starts the sender at boot.

### Wire format

One UDP datagram to port **41463** (`0xA1F7`) = `"UniExpr\0"` + 88 `float32`
Unified-Expression weights + an 11-float eye tail -> **404 bytes**.

The 88 weights are indexed by VRCFaceTracking's `UnifiedExpressions` (`Max = 88`).
The eye tail, in order:
`Version, LOpen, ROpen, LPupil, RPupil, MinDil, MaxDil, LPitch, LYaw, RPitch, RYaw`.

Read `headset/ALVR-SENDER.md` for the signal notes, and the VRCFT-ALVR-UE module
for the receiving side.

### Build the sender

Requires an Android NDK (r29 tested):

```sh
NDK=/path/to/android-ndk-r29 headset/build_alvr.sh   # -> headset/gxr_alvr
```

### Build the module zip

The module has a prebuilt `gxr_alvr`. To rebuild it from source, copy the new
built binary in first, then zip the module dir (with `module.prop` at the zip
root):

```sh
cp headset/gxr_alvr ksu-module/gxr-alvr/gxr_alvr
python tools/make_module_zip.py ksu-module/gxr-alvr gxr-alvr.zip   # any OS
# or, on Linux/macOS:
( cd ksu-module/gxr-alvr && zip -r ../gxr-alvr.zip . )
```

**Entry names must use forward slashes.** KernelSU extracts the zip on Linux, so a
Windows tool that writes `webroot\index.html` (e.g. `ZipFile.CreateFromDirectory`
or `Compress-Archive`) creates a *literal file with a backslash* at the module
root instead of a `webroot/` directory - ksud then reports `web=false` and the
module's WebUI never shows. Use `tools/make_module_zip.py` (writes `/` explicitly)
or POSIX `zip`.

The bundled binary is committed so users can install without a toolchain; if you
change `headset/gxr_alvr.c`, rebuild and re-copy it into `ksu-module/gxr-alvr/`.
The `armed` line in the log prints the binary's own version, so it is the proof
that the rebuilt binary is the one running.

### Notes

- Uprobe offsets are **firmware-specific** (developed on Galaxy XR `SM-I610`,
  firmware `I610UEU2AZF3`); the four optional probes fail soft, while the pupil
  probe (`pten`) is mandatory and an arm failure exits `rc=3`.
- The sender refuses to start a second copy (`flock`) and self-heals if tracefs is
  cleared under it. A read failure is reported as unknown, never as missing
  probes; clearing the device-wide uprobe set (which also drops other tools'
  probes) needs three consecutive confirmed misses of a probe this run had
  armed - the startup set is the baseline, so an optional probe that never armed
  cannot trigger a re-arm loop - with a 30 s floor counted from startup that
  backs off up to 10 minutes while re-arms keep failing, and at most 5 failed
  attempts before it stops and waits for an explicit restart. A main-loop gap
  longer than 15 s is logged as
  "not scheduled or was blocked ... resuming" and the relay keeps running (its
  probes and learned range survive); a 5-15 s gap is treated as a real loop
  stall and still exits for the supervisor to restart. The log also records the
  process's parent chain, cgroup and `oom_score_adj`, so an exported log shows
  whether a start ran in the Manager's app context or at boot.
- If something **outside** the module kills the relay (`rc=137`, usually the
  low-memory killer), the supervisor does not restart it: it logs why and stops,
  and you start it again from the Manager **Action** button or the WebUI. Putting
  back the probes and the ring buffer after the system decided to shed this
  process would only re-add the load it was shedding.
- Eyes can be slightly jittery on the current host DNN output.


## License

MIT: see [`LICENSE`](LICENSE).
