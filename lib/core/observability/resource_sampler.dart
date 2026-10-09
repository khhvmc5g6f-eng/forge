/// Neural Observatory — host resource sampling.
///
/// Process CPU and RSS via the POSIX `ps` tool where it exists (macOS,
/// Linux) — genuinely [MeasurementQuality.measured]. GPU utilisation is
/// **unavailable by design**: no fabricates an accelerator reading unless a
/// real telemetry source for one is wired in. The command runner is
/// injectable so tests never spawn processes.
library;

import 'dart:io';

import 'telemetry.dart';

typedef PsRunner = Future<ProcessResult> Function(
    String executable, List<String> args);

class ResourceSample {
  const ResourceSample({
    required this.at,
    required this.cpuQuality,
    required this.ramQuality,
    required this.gpuQuality,
    this.cpuPercent,
    this.rssBytes,
    this.note,
  });

  const ResourceSample.unavailable(this.at, this.note)
      : cpuPercent = null,
        rssBytes = null,
        cpuQuality = MeasurementQuality.unavailable,
        ramQuality = MeasurementQuality.unavailable,
        gpuQuality = MeasurementQuality.unavailable;

  final DateTime at;

  /// Process CPU utilisation, percent. `null` when not measurable.
  final double? cpuPercent;
  final MeasurementQuality cpuQuality;

  /// Resident set size in bytes. `null` when not measurable.
  final int? rssBytes;
  final MeasurementQuality ramQuality;

  /// Always [MeasurementQuality.unavailable] — see library doc.
  final MeasurementQuality gpuQuality;

  final String? note;

  bool get anyAvailable => cpuPercent != null || rssBytes != null;
}

class ResourceSampler {
  ResourceSampler({PsRunner? runner, int? processId})
      : _run = runner ?? Process.run,
        _pid = processId ?? pid;

  final PsRunner _run;
  final int _pid;

  /// One sample of *this* process. On any failure the sample is honest
  /// about being unavailable rather than zero-filled.
  Future<ResourceSample> sample() async {
    final at = DateTime.now();
    try {
      final result = await _run('ps', ['-o', 'rss=,%cpu=', '-p', '$_pid']);
      if (result.exitCode != 0) {
        return ResourceSample.unavailable(at, 'ps exited ${result.exitCode}');
      }
      final parts = (result.stdout as String).trim().split(RegExp(r'\s+'));
      if (parts.length < 2) {
        return ResourceSample.unavailable(at, 'unparsable ps output');
      }
      final rssKb = double.tryParse(parts[0]);
      final cpu = double.tryParse(parts[1]);
      if (rssKb == null || cpu == null) {
        return ResourceSample.unavailable(at, 'non-numeric ps output');
      }
      return ResourceSample(
        at: at,
        cpuPercent: cpu,
        cpuQuality: MeasurementQuality.measured,
        rssBytes: (rssKb * 1024).round(),
        ramQuality: MeasurementQuality.measured,
        // No telemetry source for accelerator state is wired anywhere in
        // Forge today — reported as unavailable, never invented.
        gpuQuality: MeasurementQuality.unavailable,
      );
    } catch (e) {
      return ResourceSample.unavailable(at, 'ps unavailable: $e');
    }
  }
}
