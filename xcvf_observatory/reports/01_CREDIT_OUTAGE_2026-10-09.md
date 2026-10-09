# CRITICAL — Base44 integration credits exhausted; all server-side workflows dead

- **Finding ID:** XCVF-OBS-CREDIT-001
- **Severity:** CRITICAL (platform safety net offline)
- **Detected:** 2026-10-09 ~18:00 local, by live API inspection
- **Classification:** operational outage + credit-governor design gap

## Measured evidence

1. `GET /api/apps/6a65fedb80f652b484634b58/workflows/runs?since=2026-10-02` — every
   scheduled workflow run on 2026-10-09 (and from late 2026-10-08 onward) returns
   `status: "cancelled"`, `credits_consumed: 0.0`, `status_reason: "insufficient_credits"`.
   Affected live workflows include, with today's scheduled run counts:
   - Live Ops Tick — 288 runs/day (*/5 cadence, consolidated live-tracking tick)
   - Flight Plan Overdue Scan — 144 runs/day
   - Safety Assertion Check — 96 runs/day
   - AirGuardian Biomechanics Enrichment Scan — 72 runs/day
   - AirGuardian Pipeline Health Check — 48 runs/day
   - UK NOTAM Ingestion, XContest Flight Poll, Telemetry Self Diagnostic,
     Integration Usage Rollup, Module Flow Hourly Snapshot, Entity Growth Snapshot,
     API Key Pool Self-Heal, Synthetic Health Check, AirSentry Expire Stale Monitoring,
     Club File Bin Purge, and the rest of the scheduled family.
2. **Last successful run:** `Safety Assertion Check`, 2026-10-08T02:16:07Z
   (credits_consumed 0.2). The exhaustion window is therefore
   **2026-10-08 02:16–03:00 UTC**.
3. Client-initiated backend-function invocations are presumed equally blocked for
   new billed operations (unverified end-to-end; entity reads/writes remain free
   per Base44's published rates — docs.base44.com/Account-and-billing/Credits,
   verified in docs/integration-credits/01_BASELINE_FORENSIC_AUDIT.md).

## Impact

- Server-side safety scans (NOTAM proximity, safety assertions, live-ops dead-man,
  overdue flight-plan scan, AirSentry escalation expiry) are NOT RUNNING.
- Weather/NOTAM ingestion has stopped; airspace and NOTAM data will go stale for
  any client that depends on the server feed.
- The offline-first native app continues to fly (by design), but the platform's
  central safety net and analytics ingestion are dark until credits are restored.

## Required actions (in priority order)

1. **[USER ACTION REQUIRED]** Top up / upgrade the Base44 workspace allowance.
   Forge cannot and must not purchase credits autonomously. Verify in the Base44
   workspace Credits panel (authoritative source).
2. After top-up, re-run the run-rate measurement in
   `data/credit_intel_2026-10-09.json` §method to confirm the post-remediation
   baseline of ~244 workflow credits/day (measured 2026-09-27, −79% vs baseline)
   still holds, then size the allowance to it.
3. Implement the missing Credit-Governor enforcement stage (see
   `00_MASTER_STATUS.md` Task 5): thresholds that *pause non-essential workflows*
   via `toggle-status` before the allowance hits zero, with safety-exempt
   workflows last-standing, plus a Forge-side watcher that alerts on
   `status_reason: insufficient_credits` — today's outage was invisible until
   this audit because no component outside Base44 watches for it.

## Root-cause notes

- The 2026-09-27 remediation cut workflow credits ~79% (35,300 → 7,300/month
  projected, MEASURED from Base44's own per-run credits_consumed). The allowance
  still ran out on 2026-10-08 — consistent with either a fixed monthly allowance
  being consumed by ~11 days of run-rate plus client function calls and any AI
  usage, or a smaller top-up balance. Exact split requires the Credits panel
  history, which no reachable API exposes. Not estimated further here.
- Governor gap: `IntegrationBudget` rows exist only for `client_fn` scope with
  `action: "alert"`. There is no global allowance, no suspend action, and no
  Forge-side watch — so nothing prevented or detected this outage.
