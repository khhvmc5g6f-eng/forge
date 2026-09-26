# Permissions

## Operating modes

`OperatingMode` (`lib/core/tools/tool_category.dart`): `chat`, `assist`, `agent`,
`autonomous`, `review`. Each caps the *maximum* `PermissionLevel` reachable regardless of
the user's granted level (`maxPermissionForMode`):

| Mode | Max level | Meaning |
|---|---|---|
| `chat` | 0 Observe | Discusses but never changes files |
| `review` | 1 Diagnose | Reviews existing work only |
| `assist` | 2 Propose Edits | Proposes changes; does not apply them |
| `agent` | 4 Run Build/Test | Can edit and test |
| `autonomous` | 6 Commit To AI Branch | Full loop up to committing on an isolated AI branch |

Levels 7 (Push/PR) and 8 (Production Actions) are **never** reachable purely by mode —
they always require the explicit, separately-tracked permission grant *and* still resolve
through the destructive/privileged-always-`ask` rule in `SECURITY.md` where applicable.

## The 0–8 ladder

`PermissionLevel` (`tool_category.dart`):

```
0 Observe               5 Control Test Device
1 Diagnose               6 Commit To AI Branch
2 Propose Edits          7 Push / Create PR
3 Edit Project           8 Production Actions
4 Run Build/Test
```

## How a tool call maps to a required level

`PolicyEngine._levelFor()`:

- Terminal commands: mapped from `CommandRisk` (`safe`/`read` → 0, `network` → 1,
  `install`/`build`/`test` → 4, `modify` → 3; `destructive`/`privileged` bypass level
  comparison entirely and always `ask`).
- Filesystem tools → 3 (Edit Project).
- Git tools → per-tool `explicitLevel` override: read-only (`git_status`, `git_diff`,
  `git_log`, `git_branches`) → 1 (Diagnose); mutating (`git_stage`, `git_commit`) → 6
  (Commit To AI Branch).
- GitHub tools → 7 (Push/PR).
- Build/Test/Device tools → 4 (Run Build/Test).
- Browser/Computer tools → 5 (Control Test Device).
- Database/Network/MCP tools → 1 (Diagnose).

A `Tool` can override this default via `ToolInvocation.explicitLevel` when its category is
too coarse — see `lib/core/git/git_tools.dart`'s `_GitTool.isReadOnly` for the pattern.

## Decision outcomes

`PolicyEngine.decide()` returns exactly one of:

- **`allow`** — granted level ≥ required level, and the mode permits this category.
- **`ask`** — the mode permits it, but the granted level is below what's required (or the
  action is destructive/privileged, which always asks regardless of level/mode).
- **`deny`** — the current mode's ceiling is below the required level, or the target path
  is outside the sandbox. Denial is never presented to the user as something a click can
  bypass — the mode itself must change first.

See `test/core/tools/policy_engine_test.dart` for every combination above exercised.
