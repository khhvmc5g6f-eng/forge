# CLI reference

`bin/forge.dart` is a thin executable wrapping `lib/cli/forge_cli.dart`'s
`runForgeCli()`, which only calls into `lib/core/**` — identical backend to the desktop
shell (see `ARCHITECTURE.md`). Run it during development with `dart run bin/forge.dart
<command>`; a compiled build (`dart compile exe bin/forge.dart -o forge`) produces a
standalone `forge` binary. The brief's example name `aiwork` is a straightforward alias —
`ln -s forge aiwork` or a second compiled binary with the same `runForgeCli()` entry point.

## Commands

| Command | Example | What it does |
|---|---|---|
| `open <dir>` | `forge open .` | Prints a lightweight Project Intelligence Profile: detected stack (by manifest file), Git presence/branch/changed-file count, test directory presence |
| `ask "<question>"` | `forge ask "explain this stack trace"` | Routes to the strongest suitable free model (`ModelRouter`, `TaskCategory.simpleCode`) and prints the response |
| `task "<description>" [--dir]` | `forge task "Fix failing tests"` | Creates a persisted `Task` with the default debug-workflow step checklist |
| `review --task <id> [--dir]` | `forge review --task t_123` | Prints a task's independent-review/final-review step status |
| `models` | `forge models` | Lists every model NVIDIA NIM currently reports, with capability/availability flags |
| `mcp list [--dir]` | `forge mcp list` | Connects to every server in `.forge/mcp.json` and lists discovered tools |
| `status [--dir]` | `forge status` | Project path, Git branch/changed-file count, and the ten most recent tasks |
| `resume [--dir]` | `forge resume` | Lists tasks in `running`/`blocked` state — the "RESUME TASK" recovery flow after a restart |

All commands accept `--dir <path>` (default: current working directory) where a project
root is meaningful. Every command above has been run against this repository during
development — see `NVIDIA.md` for the `models`/`ask` output and `RECOVERY.md` for
`resume`.

## Exit codes

`0` success, `1` a runtime failure (network/API error, missing task, etc.), `64` a usage
error (missing required argument) — standard CLI convention, matching what
`CommandRunner`/`UsageException` already produce.
