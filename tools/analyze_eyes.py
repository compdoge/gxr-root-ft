"""Analyze a --verbose gxr_alvr log for the two community eye reports.

  Report B (wink): does the raw eyes_closed for the winking eye reach 1.00, or
  does it top out low (which would floor openness above 0 and keep the avatar's
  lid from ever shutting)?
  Report A (squint): when the lid narrows, does the per-eye pupil reading fall
  relative to THAT EYE'S OWN open-lid baseline (occlusion being followed as if it
  were a constriction)? pu= on the gaze line is the sender's own internal ratio.

Line formats (see compute_and_send()):
  pupil (250 ms): pupil mm=.. nd=.. min=.. max=.. open=L/R eye=NN oc=NN
                  raw=L/R s=L/R closed=L/R det=<i:d<mm>/c<conf>/x<cx>/a<age> ...>
  gaze  (50 ms):  gaze t=.. ok=.. held=NN open=L/R pu=L/R
                  Ldir=.. Rdir=.. Lg=.. Rg=..
"""
import re
import sys
import statistics as st

PUP = re.compile(
    r"pupil mm=(-?\d+\.\d+) nd=(\d+) min=(-?\d+\.\d+) max=(-?\d+\.\d+) "
    r"open=(-?\d+\.\d+)/(-?\d+\.\d+) eye=(\d)(\d) oc=(\d)(\d) "
    r"raw=(-?\d+\.\d+)/(-?\d+\.\d+) s=(-?\d+\.\d+)/(-?\d+\.\d+) "
    r"closed=(-?\d+\.\d+)/(-?\d+\.\d+) det=(.*)$")
DET = re.compile(r"(\d+):d(-?\d+\.\d+)/c(-?\d+\.\d+)/x(-?\d+\.\d+)/a(\d+)")
GAZ = re.compile(
    r"gaze t=(\d+) ok=(\d+) held=(\d)(\d) open=(-?\d+\.\d+)/(-?\d+\.\d+) "
    r"pu=(-?\d+\.\d+)/(-?\d+\.\d+) ")


def pct(xs, p):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    i = min(len(xs) - 1, max(0, int(round(p / 100.0 * (len(xs) - 1)))))
    return xs[i]


def load(path):
    pup, gaz, other = [], [], 0
    for ln in open(path, "rb").read().decode("utf-8", "replace").splitlines():
        m = PUP.search(ln)
        if m:
            g = m.groups()
            rec = dict(mm=float(g[0]), nd=int(g[1]), mn=float(g[2]), mx=float(g[3]),
                       oL=float(g[4]), oR=float(g[5]),
                       eye=(int(g[6]), int(g[7])), oc=(int(g[8]), int(g[9])),
                       rL=float(g[10]), rR=float(g[11]),
                       sL=float(g[12]), sR=float(g[13]),
                       cL=float(g[14]), cR=float(g[15]),
                       det=[(int(d[0]), float(d[1]), float(d[2])) for d in DET.findall(g[16])])
            pup.append(rec)
            continue
        m = GAZ.search(ln)
        if m:
            g = m.groups()
            gaz.append(dict(t=int(g[0]), ok=int(g[1]), held=(int(g[2]), int(g[3])),
                            oL=float(g[4]), oR=float(g[5]),
                            puL=float(g[6]), puR=float(g[7])))
            continue
        other += 1
    return pup, gaz, other


def report_b(pup):
    print("== Report B: the wink ==")
    if not pup:
        print("  no pupil lines")
        return
    winks = []
    for r in pup:
        if r["cL"] - r["cR"] > 0.25:
            winks.append(("L", r))
        elif r["cR"] - r["cL"] > 0.25:
            winks.append(("R", r))
    print("  pupil frames: %d   one-eye-closed frames (|dclosed|>0.25): %d"
          % (len(pup), len(winks)))
    for side, oi, ci in (("L", "oL", "cL"), ("R", "oR", "cR")):
        vals = [r[ci] for s, r in winks if s == side]
        opens = [1.0 - r[ci] for s, r in winks if s == side]
        if not vals:
            continue
        print("  winking eye %s: n=%3d  closed max=%.2f  p95=%.2f  median=%.2f "
              "| openness min=%.2f  frames at closed>=0.95: %d"
              % (side, len(vals), max(vals), pct(vals, 95), st.median(vals),
                 min(opens), sum(1 for v in vals if v >= 0.95)))
    allc = [max(r["cL"], r["cR"]) for r in pup]
    print("  every frame, max(closedL,closedR): max=%.2f  frames>=0.99: %d  >=0.90: %d"
          % (max(allc), sum(1 for v in allc if v >= 0.99), sum(1 for v in allc if v >= 0.90)))
    # episodes: consecutive frames with one eye clearly shut
    eps, cur = [], None
    for r in pup:
        side = "L" if r["cL"] - r["cR"] > 0.25 else ("R" if r["cR"] - r["cL"] > 0.25 else None)
        if side is None:
            if cur:
                eps.append(cur); cur = None
            continue
        ci = "c" + side
        if cur is None or cur["side"] != side:
            if cur:
                eps.append(cur)
            cur = dict(side=side, n=0, maxc=0.0, minopen=1.0)
        cur["n"] += 1
        cur["maxc"] = max(cur["maxc"], r[ci])
        cur["minopen"] = min(cur["minopen"], 1.0 - r[ci])
    if cur:
        eps.append(cur)
    eps = [e for e in eps if e["n"] >= 2]
    print("  wink episodes (>=2 frames): %d" % len(eps))
    for i, e in enumerate(eps[:12], 1):
        print("    #%-2d eye %s  %2d frames  closed max=%.2f -> openness min=%.2f"
              % (i, e["side"], e["n"], e["maxc"], e["minopen"]))
    if len(eps) > 12:
        print("    ... %d more" % (len(eps) - 12))
    # a shut lid collapses that eye's detections to ~1 mm; check both eyes in a wink
    for side in ("L", "R"):
        rows = [(r, [d for d in r["det"] if d[0] >> 1 == (0 if side == "L" else 1)],
                 [d for d in r["det"] if d[0] >> 1 != (0 if side == "L" else 1)])
                for s, r in winks if s == side]
        shut = [max(d[1] for d in a) for _, a, _ in rows if a]
        openv = [max(d[1] for d in b) for _, _, b in rows if b]
        if shut and openv:
            print("  %s wink: closing-eye det median=%.2f mm, other eye=%.2f mm"
                  % (side, st.median(shut), st.median(openv)))
    print()


def report_a(pup, gaz):
    print("== Report A: squint vs pupil ==")
    if not gaz:
        print("  no gaze lines; falling back to pupil-line raw/s")
    print("  gaze-line bins by eyelid openness (pu = pupil / that eye's own open-lid baseline):")
    print("    %-14s %6s %8s %8s %8s %8s" % ("open bin", "n", "puL med", "puR med",
                                             "L<R*0.8", "held%"))
    edges = [(0.95, 1.01), (0.85, 0.95), (0.75, 0.85), (0.65, 0.75), (0.55, 0.65), (0.0, 0.55)]
    for lo, hi in edges:
        sel = [g for g in gaz if lo <= min(g["oL"], g["oR"]) < hi]
        if not sel:
            continue
        puL = [g["puL"] for g in sel if g["puL"] > 0]
        puR = [g["puR"] for g in sel if g["puR"] > 0]
        both = [g for g in sel if g["puL"] > 0 and g["puR"] > 0]
        sym = sum(1 for g in both if g["puL"] < 0.8 and g["puR"] < 0.8)
        held = sum(1 for g in sel if g["held"][0] or g["held"][1]) / float(len(sel))
        print("    %-14s %6d %8.2f %8.2f %8.1f%% %7.0f%%"
              % ("%.2f-%.2f" % (lo, hi), len(sel),
                 st.median(puL) if puL else float("nan"),
                 st.median(puR) if puR else float("nan"),
                 100.0 * sym / max(1, len(both)), 100.0 * held))
    print()
    print("  pupil lines: per-eye raw fit vs its own open-lid baseline, by openness:")
    print("    %-14s %6s %9s %9s %9s" % ("open bin", "n", "rawL/baseL", "rawR/baseR", "oc rate"))
    baseL = pct([r["rL"] for r in pup if r["oL"] >= 0.95 and r["rL"] > 0], 90)
    baseR = pct([r["rR"] for r in pup if r["oR"] >= 0.95 and r["rR"] > 0], 90)
    print("    baselines: L=%.2f mm  R=%.2f mm (p90 of raw while that lid is >=0.95)"
          % (baseL, baseR))
    for lo, hi in edges:
        sel = [r for r in pup if lo <= min(r["oL"], r["oR"]) < hi]
        if not sel:
            continue
        rl = [r["rL"] / baseL for r in sel if r["rL"] > 0 and baseL > 0]
        rr = [r["rR"] / baseR for r in sel if r["rR"] > 0 and baseR > 0]
        oc = sum(1 for r in sel if r["oc"][0] or r["oc"][1]) / float(len(sel))
        print("    %-14s %6d %9.2f %9.2f %8.0f%%"
              % ("%.2f-%.2f" % (lo, hi), len(sel),
                 st.median(rl) if rl else float("nan"),
                 st.median(rr) if rr else float("nan"), 100.0 * oc))
    print()


def main(path):
    pup, gaz, other = load(path)
    print("file: %s" % path)
    print("pupil lines=%d  gaze lines=%d  other lines=%d" % (len(pup), len(gaz), other))
    if pup:
        print("pupil coverage: %.1f s (%d frames at ~250 ms)"
              % (len(pup) * 0.25, len(pup)))
    print()
    report_b(pup)
    report_a(pup, gaz)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
