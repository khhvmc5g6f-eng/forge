/// Autonomy presets expressed in the only controls the hub protocol exposes
/// (`mode`, `autoApproveTools`, `enableSpawn`, `enableTeams`).
///
/// The CLI's `@cline/enhanced` autonomy policy also sets per-tool policies
/// (e.g. shell commands need approval at level 2). The hub `send` config has no
/// per-tool field, so the app offers four honest levels rather than pretending.
enum AutonomyLevel {
  advisory(
    label: 'Advisory',
    description: 'Plan mode. Reads and suggests; nothing runs without you.',
    mode: 'plan',
    autoApprove: false,
    spawn: false,
    teams: false,
  ),
  assisted(
    label: 'Assisted',
    description: 'Can edit and run commands, but asks before every tool call.',
    mode: 'act',
    autoApprove: false,
    spawn: false,
    teams: false,
  ),
  autonomous(
    label: 'Autonomous',
    description:
        'Completes a bounded task on its own. Tool calls auto-approved.',
    mode: 'act',
    autoApprove: true,
    spawn: false,
    teams: false,
  ),
  orchestrated(
    label: 'Orchestrated',
    description: 'Autonomous, and may spawn subagents and agent teams.',
    mode: 'act',
    autoApprove: true,
    spawn: true,
    teams: true,
  );

  const AutonomyLevel({
    required this.label,
    required this.description,
    required this.mode,
    required this.autoApprove,
    required this.spawn,
    required this.teams,
  });

  final String label;
  final String description;
  final String mode;
  final bool autoApprove;
  final bool spawn;
  final bool teams;

  /// Builds the `config` object of a hub `send` frame.
  Map<String, Object?> toConfig({String? provider, String? model}) => {
    'provider': ?provider,
    'model': ?model,
    'mode': mode,
    'enableTools': true,
    'enableSpawn': spawn,
    'enableTeams': teams,
    'autoApproveTools': autoApprove,
  };

  static AutonomyLevel fromName(String? name) => AutonomyLevel.values
      .firstWhere((l) => l.name == name, orElse: () => AutonomyLevel.assisted);
}
