import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/observability/resource_sampler.dart';
import 'package:forge/core/observability/telemetry.dart';

void main() {
  test('parses ps output into genuinely measured cpu and rss', () async {
    final sampler = ResourceSampler(
      runner: (executable, args) async =>
          ProcessResult(0, 0, '12345  12.5\n', ''),
      processId: 42,
    );
    final sample = await sampler.sample();
    expect(sample.cpuPercent, 12.5);
    expect(sample.rssBytes, 12345 * 1024);
    expect(sample.cpuQuality, MeasurementQuality.measured);
    expect(sample.ramQuality, MeasurementQuality.measured);
    expect(sample.anyAvailable, isTrue);
  });

  test('GPU stays explicitly unavailable — no invented accelerator numbers',
      () async {
    final sampler = ResourceSampler(
      runner: (executable, args) async =>
          ProcessResult(0, 0, '1000  5.0\n', ''),
      processId: 42,
    );
    final sample = await sampler.sample();
    expect(sample.gpuQuality, MeasurementQuality.unavailable);
  });

  test('ps failures yield honest unavailable samples', () async {
    final throwing = ResourceSampler(
      runner: (executable, args) async => throw const FileSystemException('no ps'),
      processId: 42,
    );
    final failed = await throwing.sample();
    expect(failed.anyAvailable, isFalse);
    expect(failed.cpuQuality, MeasurementQuality.unavailable);
    expect(failed.note, contains('unavailable'));

    final badExit = ResourceSampler(
      runner: (executable, args) async => ProcessResult(0, 1, '', 'boom'),
      processId: 42,
    );
    final exited = await badExit.sample();
    expect(exited.anyAvailable, isFalse);
    expect(exited.note, contains('exited 1'));

    final garbage = ResourceSampler(
      runner: (executable, args) async => ProcessResult(0, 0, 'not numbers', ''),
      processId: 42,
    );
    final unparsable = await garbage.sample();
    expect(unparsable.anyAvailable, isFalse);
  });
}
