import 'tool_category.dart';

/// Deterministic shell-command classifier. This is intentionally rule-based
/// rather than model-based: the whole point of the Policy Engine is that an
/// LLM's judgement never gates a destructive action. Unknown or ambiguous
/// commands classify as [CommandRisk.modify] at best, never [CommandRisk.safe],
/// so novel destructive operations fail closed into a confirmation prompt.
class CommandClassifier {
  static final List<_Rule> _rules = [
    // Privileged: always highest priority.
    _Rule(RegExp(r'\bsudo\b'), CommandRisk.privileged),
    _Rule(RegExp(r'\bdoas\b'), CommandRisk.privileged),

    // Destructive.
    _Rule(RegExp(r'\brm\s+.*-[a-z]*r[a-z]*f|\brm\s+.*-[a-z]*f[a-z]*r'), CommandRisk.destructive),
    _Rule(RegExp(r'\brm\s+-rf\b'), CommandRisk.destructive),
    _Rule(RegExp(r'\bgit\s+push\s+.*--force\b'), CommandRisk.destructive),
    _Rule(RegExp(r'\bgit\s+push\s+.*-f\b'), CommandRisk.destructive),
    _Rule(RegExp(r'\bgit\s+reset\s+--hard\b'), CommandRisk.destructive),
    _Rule(RegExp(r'\bgit\s+clean\s+.*-[a-z]*f'), CommandRisk.destructive),
    _Rule(RegExp(r'\bdrop\s+(table|database)\b', caseSensitive: false), CommandRisk.destructive),
    _Rule(RegExp(r'\bmkfs\b'), CommandRisk.destructive),
    _Rule(RegExp(r'>\s*/dev/sd'), CommandRisk.destructive),

    // Modify: state-changing but reversible via Git/checkpoint.
    _Rule(RegExp(r'\bgit\s+commit\b'), CommandRisk.modify),
    _Rule(RegExp(r'\bgit\s+push\b'), CommandRisk.modify),
    _Rule(RegExp(r'\bgit\s+merge\b'), CommandRisk.modify),
    _Rule(RegExp(r'\bgit\s+rebase\b'), CommandRisk.modify),
    _Rule(RegExp(r'\bgit\s+checkout\s+-b\b'), CommandRisk.modify),
    _Rule(RegExp(r'\bgit\s+branch\s+-d\b'), CommandRisk.modify),
    _Rule(RegExp(r'\bmv\b'), CommandRisk.modify),
    _Rule(RegExp(r'\brm\b'), CommandRisk.modify),
    _Rule(RegExp(r'\bchmod\b'), CommandRisk.modify),
    _Rule(RegExp(r'\bchown\b'), CommandRisk.modify),

    // Network: outbound calls that aren't package installs.
    _Rule(RegExp(r'\bcurl\b'), CommandRisk.network),
    _Rule(RegExp(r'\bwget\b'), CommandRisk.network),
    _Rule(RegExp(r'\bgit\s+clone\b'), CommandRisk.network),
    _Rule(RegExp(r'\bgit\s+fetch\b'), CommandRisk.network),
    _Rule(RegExp(r'\bgit\s+pull\b'), CommandRisk.network),
    _Rule(RegExp(r'\bssh\b'), CommandRisk.network),
    _Rule(RegExp(r'\bscp\b'), CommandRisk.network),

    // Install.
    _Rule(RegExp(r'\bnpm\s+install\b'), CommandRisk.install),
    _Rule(RegExp(r'\byarn\s+add\b'), CommandRisk.install),
    _Rule(RegExp(r'\bpip\s+install\b'), CommandRisk.install),
    _Rule(RegExp(r'\bflutter\s+pub\s+(get|add)\b'), CommandRisk.install),
    _Rule(RegExp(r'\bbrew\s+install\b'), CommandRisk.install),
    _Rule(RegExp(r'\bpod\s+install\b'), CommandRisk.install),
    _Rule(RegExp(r'\bapt(-get)?\s+install\b'), CommandRisk.install),

    // Test.
    _Rule(RegExp(r'\bflutter\s+test\b'), CommandRisk.test),
    _Rule(RegExp(r'\bnpm\s+(run\s+)?test\b'), CommandRisk.test),
    _Rule(RegExp(r'\bpytest\b'), CommandRisk.test),
    _Rule(RegExp(r'\bdart\s+test\b'), CommandRisk.test),
    _Rule(RegExp(r'\bgo\s+test\b'), CommandRisk.test),

    // Build.
    _Rule(RegExp(r'\bflutter\s+(build|run)\b'), CommandRisk.build),
    _Rule(RegExp(r'\bnpm\s+run\s+build\b'), CommandRisk.build),
    _Rule(RegExp(r'\bxcodebuild\b'), CommandRisk.build),
    _Rule(RegExp(r'\bgradle\b|\.\/gradlew\b'), CommandRisk.build),
    _Rule(RegExp(r'\bmake\b'), CommandRisk.build),
    _Rule(RegExp(r'\bcargo\s+build\b'), CommandRisk.build),

    // Read / safe.
    _Rule(RegExp(r'\bgit\s+status\b'), CommandRisk.safe),
    _Rule(RegExp(r'\bgit\s+(diff|log|show|branch)\b'), CommandRisk.read),
    _Rule(RegExp(r'\bflutter\s+(analyze|doctor)\b'), CommandRisk.safe),
    _Rule(RegExp(r'^(ls|cat|pwd|find|grep|head|tail|wc|which|echo)\b'), CommandRisk.safe),
    _Rule(RegExp(r'\bps\b|\btop\b|\bdf\b|\bdu\b'), CommandRisk.read),
  ];

  /// Classifies [command]. Falls back to [CommandRisk.modify] for anything
  /// unrecognised, since an unknown command must never be treated as safe.
  CommandRisk classify(String command) {
    final trimmed = command.trim();
    for (final rule in _rules) {
      if (rule.pattern.hasMatch(trimmed)) return rule.risk;
    }
    return CommandRisk.modify;
  }
}

class _Rule {
  const _Rule(this.pattern, this.risk);
  final RegExp pattern;
  final CommandRisk risk;
}
