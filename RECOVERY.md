# Recovery

## Task persistence

Every `Task` (`lib/core/tasks/task.dart`) is written to
`<project>/.forge/tasks/<task-id>.json` by `FileTaskStore`
(`lib/core/tasks/task_store.dart`) on every state change — creation, step
begin/complete/fail, checkpoint recorded, agent/model recorded, repair/review cycle
recorded. There is no in-memory-only task state in the production path (`InMemoryTaskStore`
exists solely for tests). `.forge/` is excluded from Git (`.gitignore`) — it is local,
per-project runtime state, not something to commit or share.

## What survives a restart

A freshly started `TaskManager`/`FileTaskStore` pointed at the same project directory reads
every task file back with:

- Full step checklist and each step's status (`pending`/`inProgress`/`done`/`failed`/`skipped`)
- `lastCompletedStep` — exactly where the task left off
- The isolated branch name, if one was created
- Every checkpoint ID recorded
- Every agent ID and model key that touched the task
- Repair-iteration and review-cycle counts, so budgets aren't reset by a restart

This is verified directly in `test/core/tasks/task_manager_test.dart`'s `a task survives a
simulated restart via FileTaskStore` — the test constructs a **second, independent**
`TaskManager` instance against the same directory and confirms it sees the first instance's
progress. A corrupted/partial JSON file from a crash mid-write is skipped during
`loadAll()` rather than failing the whole resume flow.

## Resuming

`TaskManager.resumableTasks()` returns every task in `running` or `blocked` state.
`forge resume` (`lib/cli/forge_cli.dart`) surfaces this at the CLI; the desktop shell's
Tasks panel lists every task regardless of status with its live step checklist, so a
`blocked` task (repair or review budget exhausted, or a step explicitly failed) is
immediately visible rather than silently stuck.

## Checkpoints and rollback

`CheckpointManager` (`lib/core/git/checkpoint.dart`) records `{branch, headCommitSha,
dirtyFilesAtCheckpoint, taskId, timestamp}` before significant modifications.
`rollbackToCheckpoint()` performs a `git reset --hard` to the checkpoint's commit —
correctly modelled as a destructive operation the Policy Engine gates (see `SECURITY.md`);
this method itself does not check policy and must only be called after that confirmation
has already happened. `rollbackTask()` restores the earliest checkpoint recorded for a
task, for a full "undo everything this task did" action.

## What is not yet covered

- Recovering a task that was mid-`AgentRuntime.run()` when the process died — the task's
  step checklist correctly shows the last *completed* step, but resuming execution
  mid-agent-loop (rather than restarting the current step from scratch) is not yet
  implemented.
- Automatic reconnection of MCP server connections on resume — `McpManager` state is
  in-memory only today; a resumed task referencing an MCP tool will need those servers
  reconnected via `.forge/mcp.json` before continuing.
