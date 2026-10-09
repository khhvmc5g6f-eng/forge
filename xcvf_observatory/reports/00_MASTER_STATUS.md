# XCVF Master Status — 31-task programme vs. ground truth (2026-10-09)

Legend: **MEASURED** (live API / executed command), **VERIFIED** (source file read),
**ESTIMATED** (arithmetic, not billing data), **GAP** (work remaining).

A large part of this programme was already executed by prior XCVF work-streams
(`docs/integration-credits/`, `docs/jev-audit/`, PRs #42–#79). This report states,
per task, what exists with evidence, what is live-verified today, and what remains.

## Phase 1 — Discovery & audit

- **T1 Architecture discovery — DONE.** Monorepo: `app/` (Flutter, ~2,084 lib
  Dart files + ~1,400 module files), `web/` (React/Vite + Base44 mirror),
  `services/` (http-proxy, ogn-worker), `firmware/` (nRF52). 491 Base44
  entities. 4 CI workflows. Inventory: `../data/architecture_inventory.json`.
  **GAP:** no rendered dependency-graph screen in the Forge app yet; the data
  and the 232-finding register (`docs/jev-audit/04_DEFECT_REGISTER.md`) exist
  to feed it.
- **T2 Automated code analysis — PARTIAL.** Baseline 2026-10-03 (VERIFIED
  `docs/jev-audit/evidence/verify.md`): 12,926/12,995 Flutter tests passed,
  57 failed. Fresh `flutter analyze` launched 2026-10-09. **GAP:** re-run full
  test suite on current origin/main and triage the 57 failures.

## Phase 2 — Base44 credit audit (priority)

- **T3 — DONE previously, re-verified live today.** Root cause was never AI:
  14 five-minute automations were 73% of 38,257 runs/7d (MEASURED 2026-09-26).
  Metering covers 100% of credit-bearing calls (46 calls / 36 files) and
  78/78 workflow-invoked functions (VERIFIED `metering_coverage.md`).
  Live entities confirmed today: `IntegrationUsageEvent`, `IntegrationUsageRollup`,
  `IntegrationBudget`.
- **T4 — NEW CRITICAL FINDING:** workspace **out of credits since 2026-10-08
  02:16 UTC** (MEASURED: every run `status_reason: insufficient_credits`).
  See `01_CREDIT_OUTAGE_2026-10-09.md`.
- **T5 Credit Governor — SKELETON EXISTS, ENFORCEMENT GAP.** Budgets are
  `client_fn`-scoped, `action: "alert"` only (MEASURED, 9 rows). Missing:
  global allowance, forecast, pre-zero suspension of non-essential workflows
  (safety-exempt last), Forge-side outage watcher. **Top new build item.**
- **T6 — DONE for the Sept remediation** (−79% MEASURED from Base44's own
  credits_consumed: 1,177 → 244 credits/day). New baseline needed post-top-up.

## Phase 3 — Native Flutter independence

- **T7/T8 — largely designed** (`FREE_SYNC_ARCHITECTURE.md`,
  `SECURE_KEY_DISTRIBUTION.md`, `free_sync_migration.md`): key-holding relays
  stay server-side; direct/free paths migrate. Drift/SQLite local DB exists
  (`app_database.dart`, schema v42 main vs v45/47 on branch lines — VERIFIED
  REPO-005 collision risk). **GAP:** schema-version unification.
- **T9 — EXISTS** (offline-first repositories, Black Box, flutter_secure_storage).
  Known defects OFFLINE-008/009: unwired offline repositories; DB-key loss
  silently degrades queue durability. **GAP:** close both.
- **T10–T12 — partially landed** (PR #68 stale-data/degraded-states, freshness
  TTLs). **GAP:** battery-aware backpressure; request metrics in Observatory.

## Phase 4 — Flight systems debugging

- **T13–T15 — audited** (`docs/jev-audit/`: instruments, weather, airspace,
  traffic, emergency, planning; hardware diagnostics; replay engine). The five
  S1 root problems of 2026-10-03 have since **merged on origin/main** — all
  VERIFIED in the 128-commit delta: PR #43 emergency-keeps-flight-airborne
  (INTEL-002), #55 SOS offline retry + honest state (OFFLINE-001/003),
  #59 crash-evidence-reaches-escalation-threshold (INTEL-001), #58 burst
  cancel + false triggers (REPO-001), #54 membership (REPO-002), #46 firmware
  airtime gate (RADIO-001), #56 secure token storage, #53 migration tests,
  #51 macOS build. **GAP:** local checkout is 128 commits behind —
  fast-forward before further local verification; merged fixes not re-verified
  on a fresh checkout by this session.

## Phase 5 — Unified analytics

- **T16–T20 — architecture exists** (`ClientTelemetryBatch` batch upload,
  usage event/rollup pipeline with 30d/14d GDPR retention, admin panels,
  `docs/mobile-gateway-api-v1.md`). **GAP:** end-to-end verification of
  cross-platform event flow not performed this session.

## Phase 6 — Visual parity

- **T21–T24 — begun** (PR #60 docs/frontend-parity merged). **GAP:** automated
  golden/screenshot comparison suite not evidenced on CI.

## Phase 7 — Autonomous repair engine

- **T25–T28 — process exists**; the defect→register→PR→review→merge
  discipline is visible throughout the commit history; JEV decision
  architecture documented (`docs/jev-audit/06_DECISION_ARCHITECTURE.md`).
  This Observatory directory is its permanent Forge home. **GAP:** Oversight
  gate stays human for flight-critical changes (by design, keep it).

## Phases 8–9 — Observatory & validation

- This file set is the Observatory's first release; Forge-app dashboard UI
  pending, fed by `../data/*.json`.
- **T29–T31:** test matrix last measured 2026-10-03 (12,926/12,995 pass,
  57 fail). **Not re-measured this session** — stale checkout; a fresh
  sync + full `flutter test` is the next verification gate. No further claims.

## Priority queue (next actions, in order)

1. **USER:** restore Base44 credits (unblocks the server-side safety net).
2. **FORGE:** build the Credit-Governor suspend stage + outage watcher (T5 GAP).
3. **FORGE:** fast-forward the local repo to origin/main; re-run full
   `flutter test`; triage the 57 failures against new HEAD.
4. **FORGE:** unify the Drift schema-version collision (REPO-005) before release.
5. **FORGE:** close OFFLINE-008/009.
6. **FORGE:** Observatory dashboard screens in the Forge app, fed by this data.

