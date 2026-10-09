# XCVF System Observatory

Permanent diagnostics and optimisation workspace for the XCVF ecosystem, built and
maintained by Forge. Established **2026-10-09** from a full live discovery pass.

## Scope of the XCVF ecosystem (all verified 2026-10-09)

| Component | Location | Evidence |
|---|---|---|
| Base44 web platform | Base44 app "XC Vario Flight" `6a65fedb80f652b484634b58` (status: ready) | live API |
| Base44 web source | `/Volumes/Mac Laptop/XCVarioFlight/web/` (React/Vite, `web/base44/` mirror) | file system |
| Native Flutter app | `/Volumes/Mac Laptop/XCVarioFlight/app/` (`xcvarioflight_app`, v1.0.0+4, Dart SDK ^3.12.2) | pubspec.yaml |
| Flutter module library | `/Volumes/Mac Laptop/XCVarioFlight/app/modules/` (~1,400 Dart files) | find |
| Shared backend functions | `web/base44/functions/` (78 workflow-invoked functions, all metered) | metering_coverage.md |
| Support services | `services/http-proxy`, `services/ogn-worker` | file system |
| Firmware | `firmware/` (nRF52, PlatformIO) | file system |
| Git remote | `https://github.com/khhvmc5g6f-eng/XC-Vario-Flight.git` | git remote -v |
| Local Flutter SDK | `~/development/flutter` 3.44.8 / Dart 3.12.2 | flutter --version |
| Base44 entity schemas | 491 entities in app `6a65fedb80f652b484634b58` | live API |
| Prior forensic audits | `docs/integration-credits/` (credit forensics), `docs/jev-audit/` (232-finding defect register) | file system |

## Contents

- `reports/00_MASTER_STATUS.md` — status of all 31 programme tasks, with evidence and gaps
- `reports/01_CREDIT_OUTAGE_2026-10-09.md` — **critical live finding**: Base44 credits exhausted
- `data/architecture_inventory.json` — machine-readable component inventory
- `data/credit_intel_2026-10-09.json` — live credit-consumption snapshot (measured)

## Rules (inherited from the XCVF audit culture)

1. Every number is labelled **MEASURED** (from a live API or executed command),
   **VERIFIED** (read from source with file:line) or **ESTIMATED** (arithmetic, not billing data).
2. Base44's authoritative credit balance is the workspace Credits panel; no reachable API
   exposes it. Estimates are never presented as billing data.
3. A cancelled/failed run is not a passed run. A stale checkout is not the shipped system.
4. Never test on live flights. Reproduce with recorded traces and simulation only.
