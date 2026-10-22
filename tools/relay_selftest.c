/* Offline unit test for the sender paths that need no root and no tracefs.
 *
 * The relay's real start path needs root, tracefs and the vendor libraries, so
 * this harness includes the sender source (renaming its main) and calls only:
 *   - log_process_context(): the startup diagnostic (one bounded line, stderr);
 *   - on_alarm(): the watchdog's no-op, long-gap-resume, maintenance and
 *     maintenance-overrun cases, including the deferred log-marker reset;
 *   - probe_snapshot()/tracing_enabled() on a host with no tracefs: both must
 *     report "unknown" (-1), never "nothing there" (0), and an unknown read must
 *     leave no probe bits set;
 *   - probe bit helpers, probe_mask_from_arms() and rearm_allowed(): the
 *     startup baseline comes from arm results (not the event-list snapshot) and
 *     the first re-arm obeys the 30 s floor;
 *   - hc_verdict(): the quiet-episode wording must not claim more than the
 *     health check established (in particular it must never say probes are
 *     present when their state is suspect or unknown).
 * The ordinary-stall branch calls _exit(1) and is therefore not run here; that
 * branch is checked structurally in tools/modtest.sh.
 *
 * Build:  cc -O2 -Wall -Wextra -o relay_selftest tools/relay_selftest.c -lm
 * Run:    ./relay_selftest        (exit 0 = pass; "ok"/"FAIL" lines on stdout)
 */
#define main gxr_alvr_program_main
#include "../headset/gxr_alvr.c"
#undef main

static int check(const char *what, int cond) {
    printf("%s %s\n", cond ? "ok" : "FAIL", what);
    return cond ? 0 : 1;
}

int main(void) {
    int bad = 0;

    /* 1. Startup diagnostic: prints exactly one line to stderr. */
    log_process_context();

    /* 2. A fresh progress marker is not a stall. */
    g_maint = 0;
    g_loopTickMs = now_ms();
    int gaps = (int)g_longGaps;
    on_alarm(0);
    bad += check("watchdog ignores a fresh marker", (int)g_longGaps == gaps);

    /* 3. A long gap resumes instead of exiting and counts the gap. The handler
          only sets a flag for the log-write marker; the main loop owns that
          64-bit value, so the handler must not write it. */
    long long old = now_ms() - (LONG_GAP_MS + 5000);
    g_loopTickMs = old;
    g_printStartMs = old;
    g_printReset = 0;
    on_alarm(0);
    bad += check("watchdog resumes after a long gap", (int)g_longGaps == gaps + 1);
    bad += check("watchdog resets the progress marker", g_loopTickMs > old);
    bad += check("watchdog requests the log-marker reset", g_printReset == 1);
    bad += check("watchdog leaves the 64-bit log marker to the main loop",
                 g_printStartMs == old);
    g_printReset = 0;   /* main-loop equivalent, so later checks start clean */

    /* 4. The maintenance window stays exempt even after a long gap. */
    g_maint = 1;
    g_maintStartMs = now_ms();
    g_maintWarned = 0;
    g_loopTickMs = now_ms() - (LONG_GAP_MS + 5000);
    int gaps2 = (int)g_longGaps;
    on_alarm(0);
    bad += check("watchdog stays quiet during fresh maintenance", (int)g_longGaps == gaps2);
    bad += check("fresh maintenance is not warned about", g_maintWarned == 0);

    /* 5. Maintenance that does not return is reported once, without exiting and
          without touching the progress markers (no false stall diagnosis). */
    g_maintStartMs = now_ms() - (MAINT_WARN_MS + 5000);
    g_maintWarned = 0;
    long long tick = g_loopTickMs;
    on_alarm(0);
    bad += check("overrunning maintenance is reported", g_maintWarned == 1);
    bad += check("overrunning maintenance does not move the progress marker",
                 g_loopTickMs == tick);
    g_maint = 0;

    /* 6. Without tracefs the read is UNKNOWN (-1), not "nothing there" (0), and
          an unknown read must not leave a partial mask behind. */
    unsigned pm = PROBE_ALL;
    bad += check("probe_snapshot reports unknown when tracefs is absent", probe_snapshot(&pm) < 0);
    bad += check("unknown probe read leaves no probe bits set", pm == 0);
    bad += check("tracing_enabled reports unknown when tracefs is absent", tracing_enabled() < 0);

    /* 7. Probe bit helpers: pten is bit 0 and the full mask has five bits. */
    bad += check("pten is the mandatory bit", PROBE_PTEN == 1u);
    bad += check("probe_count counts the full mask", probe_count(PROBE_ALL) == 5);
    bad += check("probe_count ignores spare bits", probe_count(PROBE_ALL | 0x80u) == 5);

    /* 8. The startup baseline is built from arm results, never the snapshot:
          a successfully armed optional probe stays required even if the
          observational read failed. 0 = arm success. */
    bad += check("arm mask: pten only", probe_mask_from_arms(0, -1, -1, -1, -1) == PROBE_PTEN);
    bad += check("arm mask: all probes armed", probe_mask_from_arms(0, 0, 0, 0, 0) == PROBE_ALL);
    bad += check("arm mask tracks individual optional failures",
                 probe_mask_from_arms(0, 0, -1, 0, -1) ==
                 (PROBE_PTEN | PROBE_BIT(1) | PROBE_BIT(3)));
    bad += check("arm mask drops a failed mandatory probe",
                 probe_mask_from_arms(-1, 0, 0, 0, 0) == (PROBE_ALL & ~PROBE_PTEN));

    /* 9. Re-arm floor: the startup cleanup starts the clock, so the first
          destructive re-arm waits REARM_MIN_MS; backoff grows and is capped. */
    long long t0 = 1000;
    bad += check("first re-arm blocked before 30 s", rearm_allowed(t0 + 9000, t0, 0) == 0);
    bad += check("first re-arm blocked at 29.999 s",
                 rearm_allowed(t0 + REARM_MIN_MS - 1, t0, 0) == 0);
    bad += check("first re-arm allowed at 30 s", rearm_allowed(t0 + REARM_MIN_MS, t0, 0) == 1);
    bad += check("one failure doubles the floor",
                 rearm_allowed(t0 + REARM_MIN_MS, t0, 1) == 0);
    bad += check("one failure allowed at 60 s",
                 rearm_allowed(t0 + 2 * REARM_MIN_MS, t0, 1) == 1);
    bad += check("backoff caps at REARM_MAX_MS", rearm_backoff_ms(20) == REARM_MAX_MS);
    bad += check("legacy unset floor still allows", rearm_allowed(5000, 0, 0) == 1);

    /* 10. The quiet-episode verdict must match what was verified. */
    char v[192];
    hc_verdict(HC_PROBES_OK, v, sizeof(v));
    bad += check("healthy verdict says healthy", strstr(v, "healthy") != NULL);
    hc_verdict(HC_PROBES_UNKNOWN, v, sizeof(v));
    bad += check("unknown verdict says it could not verify", strstr(v, "could not be verified") != NULL);
    bad += check("unknown verdict does not say healthy", strstr(v, "healthy") == NULL);
    hc_verdict(HC_PROBES_SUSPECT, v, sizeof(v));
    bad += check("suspect verdict says probes are missing", strstr(v, "missing some of our probes") != NULL);
    bad += check("suspect verdict does not claim a re-arm", strstr(v, "re-armed") == NULL);
    hc_verdict(HC_REARMED | HC_PROBES_OK, v, sizeof(v));
    bad += check("re-armed verdict says re-armed", strstr(v, "re-armed") != NULL);
    hc_verdict(HC_REARMED | HC_PROBES_SUSPECT, v, sizeof(v));
    bad += check("failed re-arm verdict does not claim a restore",
                 strstr(v, "did not restore") != NULL);
    hc_verdict(HC_PROBES_SUSPECT | HC_REARM_GAVEUP, v, sizeof(v));
    bad += check("gave-up verdict says re-arming stopped",
                 strstr(v, "automatic re-arming has stopped") != NULL);
    bad += check("gave-up verdict does not promise another attempt",
                 strstr(v, "needed before re-arming") == NULL);
    hc_verdict(HC_REARMED | HC_PROBES_SUSPECT | HC_REARM_GAVEUP, v, sizeof(v));
    bad += check("final failed re-arm verdict says re-arming stopped",
                 strstr(v, "automatic re-arming has stopped") != NULL);
    hc_verdict(HC_PROBES_OK | HC_TRACING_FAILED, v, sizeof(v));
    bad += check("failed re-enable verdict does not claim success",
                 strstr(v, "could not be re-enabled") != NULL);
    hc_verdict(HC_PROBES_OK | HC_TRACING_UNKNOWN, v, sizeof(v));
    bad += check("unreadable tracing_on verdict does not claim healthy",
                 strstr(v, "healthy") == NULL);

    /* F1 regression: an unknown or suspect probe state must never be reported
       as "probes are present" just because tracing_on is the broken part. */
    hc_verdict(HC_PROBES_UNKNOWN | HC_TRACING_UNKNOWN, v, sizeof(v));
    bad += check("unknown probes + unknown tracing does not claim present",
                 strstr(v, "present") == NULL);
    hc_verdict(HC_PROBES_SUSPECT | HC_TRACING_UNKNOWN, v, sizeof(v));
    bad += check("suspect probes + unknown tracing does not claim present",
                 strstr(v, "present") == NULL);
    hc_verdict(HC_PROBES_UNKNOWN | HC_TRACING_FIXED, v, sizeof(v));
    bad += check("unknown probes + re-enabled tracing does not claim present",
                 strstr(v, "present") == NULL);
    hc_verdict(HC_PROBES_OK | HC_TRACING_FIXED, v, sizeof(v));
    bad += check("verified probes + re-enabled tracing says both",
                 strstr(v, "present") != NULL && strstr(v, "re-enabled") != NULL);

    printf("selftest_bad=%d\n", bad);
    return bad ? 1 : 0;
}
