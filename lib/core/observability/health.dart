/// Neural Observatory — the Forge Health Index.
///
/// Eight component scores with documented weights, normalised to [0, 1].
/// The rule that matters most here: **a missing measurement is not a
/// passing check.** Components without data contribute nothing to the
/// overall score and reduce [coverage] instead — the panel always shows
/// both the score and how much of the system it actually measured.
library;

enum HealthComponent {
  sessionResponsiveness,
  modelAvailability,
  apiReliability,
  agentExecution,
  networkPerformance,
  infrastructure,
  errorFrequency,
  resourcePressure,
}

class ComponentHealth {
  const ComponentHealth({
    required this.component,
    required this.score,
    required this.detail,
  });

  const ComponentHealth.unavailable(this.component, this.detail)
      : score = null;

  final HealthComponent component;

  /// 0 (worst) to 1 (best); null means "no measurement" — excluded from
  /// the overall score, subtracted from coverage.
  final double? score;
  final String detail;
}

class HealthIndexReport {
  const HealthIndexReport({
    required this.overall,
    required this.coverage,
    required this.components,
    required this.methodology,
  });

  /// Weighted mean over the components that actually have data; null when
  /// nothing has been measured yet — rendered "no data", never 100%.
  final double? overall;

  /// Fraction (0..1) of components with data — displayed beside the score.
  final double coverage;
  final List<ComponentHealth> components;
  final String methodology;
}

class HealthIndex {
  HealthIndex({Map<HealthComponent, double>? weights})
      : _weights = weights ?? defaultWeights;

  /// Default weights, published here so the score is reproducible by hand.
  /// Responsiveness, availability and reliability carry the platform:
  /// they are what the user actually experiences. Error frequency and
  /// resource pressure are early-warning components rather than primary
  /// user pain, so they weigh less.
  static const Map<HealthComponent, double> defaultWeights = {
    HealthComponent.sessionResponsiveness: 0.20,
    HealthComponent.modelAvailability: 0.20,
    HealthComponent.apiReliability: 0.15,
    HealthComponent.agentExecution: 0.10,
    HealthComponent.networkPerformance: 0.10,
    HealthComponent.infrastructure: 0.10,
    HealthComponent.errorFrequency: 0.075,
    HealthComponent.resourcePressure: 0.075,
  };

  final Map<HealthComponent, double> _weights;

  HealthIndexReport compute(List<ComponentHealth> components) {
    final byComponent = {
      for (final c in components) c.component: c,
    };
    var weightSum = 0.0;
    var scoreSum = 0.0;
    var withData = 0;
    final ordered = HealthComponent.values.map((k) {
      final c = byComponent[k];
      final w = _weights[k] ?? defaultWeights[k] ?? 0.0;
      if (c == null || c.score == null) {
        return ComponentHealth.unavailable(
            k, c?.detail ?? 'No telemetry for this component yet.');
      }
      withData++;
      weightSum += w;
      scoreSum += (c.score!.clamp(0.0, 1.0)) * w;
      return c;
    }).toList();

    final coverage =
        HealthComponent.values.isEmpty ? 0.0 : withData / HealthComponent.values.length;
    final overall = weightSum == 0 ? null : scoreSum / weightSum;
    return HealthIndexReport(
      overall: overall,
      coverage: coverage,
      components: ordered,
      methodology:
          'Weighted mean over components with data (weights sum per set: '
          'responsiveness .20, availability .20, reliability .15, agents .10, '
          'network .10, infrastructure .10, errors .075, resources .075). '
          'Components without measurements are excluded and reduce coverage '
          '— they never count as healthy.',
    );
  }
}
