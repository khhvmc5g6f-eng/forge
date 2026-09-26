/// Tool categories from the brief's Tool Gateway diagram.
enum ToolCategory {
  filesystem,
  terminal,
  git,
  github,
  browser,
  computer,
  build,
  test,
  device,
  database,
  network,
  mcp,
}

/// The command-risk taxonomy from the brief. Every terminal command is
/// classified into exactly one of these before the [PolicyEngine] decides
/// whether it may run.
enum CommandRisk {
  safe,
  read,
  build,
  test,
  install,
  network,
  modify,
  destructive,
  privileged,
}

/// The five operating modes from the brief. Each mode caps the maximum
/// [PermissionLevel] available regardless of what the user's permission
/// configuration otherwise allows — Review Mode, for instance, can never
/// edit files even if the project's permission level is 8.
enum OperatingMode { chat, assist, agent, autonomous, review }

/// The granular 0–8 permission ladder from the brief.
enum PermissionLevel {
  observe(0),
  diagnose(1),
  proposeEdits(2),
  editProject(3),
  runBuildTest(4),
  controlTestDevice(5),
  commitToAiBranch(6),
  pushOrCreatePr(7),
  productionActions(8);

  const PermissionLevel(this.rank);
  final int rank;

  bool atLeast(PermissionLevel other) => rank >= other.rank;
}

const Map<OperatingMode, PermissionLevel> maxPermissionForMode = {
  OperatingMode.chat: PermissionLevel.observe,
  OperatingMode.review: PermissionLevel.diagnose,
  OperatingMode.assist: PermissionLevel.proposeEdits,
  OperatingMode.agent: PermissionLevel.runBuildTest,
  // Autonomous mode may still reach 6 (commit to an AI-owned branch) without
  // further confirmation; 7 (push/PR) and 8 (production) always require an
  // explicit human approval regardless of mode, per SECURITY.md.
  OperatingMode.autonomous: PermissionLevel.commitToAiBranch,
};
