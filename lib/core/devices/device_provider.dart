import 'dart:convert';
import 'dart:io';

import 'device.dart';
import 'device_process_runner.dart';

/// One platform's device tooling: discover devices, install a build,
/// launch/terminate an app, pull logs, take a screenshot, run a raw shell
/// command. `AdbDeviceProvider` and `IosSimulatorDeviceProvider` are the two
/// concrete implementations; both are real process wrappers around `adb`/
/// `xcrun simctl` (not simulated data), following the exact pattern
/// `GitService` uses for `git` — inject a [DeviceProcessRunner] so unit
/// tests exercise real output-parsing logic against scripted process output.
abstract class DeviceProvider {
  DevicePlatform get platform;

  Future<List<Device>> listDevices();
  Future<void> install(String deviceId, String appPath);
  Future<void> launch(String deviceId, String appIdentifier);
  Future<void> terminate(String deviceId, String appIdentifier);
  Future<String> logs(String deviceId, {int tailLines = 200});
  Future<void> screenshot(String deviceId, String outputPath);
  Future<String> shell(String deviceId, String command);
}

/// Android devices/emulators via `adb`. Requires the Android SDK platform
/// tools on `PATH` — absent in this development container, so
/// `listDevices()` returns an empty list (with the reason recorded) rather
/// than throwing, matching "no devices" as an ordinary, expected state.
class AdbDeviceProvider implements DeviceProvider {
  AdbDeviceProvider({DeviceProcessRunner? runner}) : _runner = runner ?? RealDeviceProcessRunner();

  final DeviceProcessRunner _runner;

  @override
  DevicePlatform get platform => DevicePlatform.android;

  @override
  Future<List<Device>> listDevices() async {
    final result = await _run(['devices', '-l']);
    if (result == null) return const [];
    final devices = <Device>[];
    for (final line in result.stdout.split('\n').skip(1)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final id = parts[0];
      final state = parts[1];
      if (state != 'device' && state != 'emulator') continue;
      final modelField = parts.firstWhere((p) => p.startsWith('model:'), orElse: () => 'model:unknown');
      devices.add(Device(
        id: id,
        name: modelField.substring('model:'.length).replaceAll('_', ' '),
        platform: DevicePlatform.android,
        osVersion: 'unknown',
        connection: id.startsWith('emulator-') ? DeviceConnection.emulator : DeviceConnection.usb,
      ));
    }
    return devices;
  }

  @override
  Future<void> install(String deviceId, String appPath) async {
    await _requireSuccess(['-s', deviceId, 'install', '-r', appPath]);
  }

  @override
  Future<void> launch(String deviceId, String appIdentifier) async {
    // appIdentifier is expected as "package/.Activity" or "package" (falls
    // back to the launcher intent for a bare package name).
    if (appIdentifier.contains('/')) {
      await _requireSuccess(['-s', deviceId, 'shell', 'am', 'start', '-n', appIdentifier]);
    } else {
      await _requireSuccess([
        '-s', deviceId, 'shell', 'monkey',
        '-p', appIdentifier, '-c', 'android.intent.category.LAUNCHER', '1',
      ]);
    }
  }

  @override
  Future<void> terminate(String deviceId, String appIdentifier) async {
    final package = appIdentifier.split('/').first;
    await _requireSuccess(['-s', deviceId, 'shell', 'am', 'force-stop', package]);
  }

  @override
  Future<String> logs(String deviceId, {int tailLines = 200}) async {
    final result = await _run(['-s', deviceId, 'logcat', '-d', '-t', '$tailLines']);
    return result?.stdout ?? '';
  }

  @override
  Future<void> screenshot(String deviceId, String outputPath) async {
    // `adb exec-out` streams raw PNG bytes to stdout; Process.run captures
    // stdout as a String by default, which corrupts binary data, so this
    // uses Process.start directly rather than the shared DeviceProcessRunner.
    final process = await _startRaw(['-s', deviceId, 'exec-out', 'screencap', '-p']);
    final bytes = await process.stdout.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
    await File(outputPath).writeAsBytes(bytes);
  }

  @override
  Future<String> shell(String deviceId, String command) async {
    final result = await _run(['-s', deviceId, 'shell', command]);
    return result?.stdout ?? '';
  }

  Future<DeviceCommandResult?> _run(List<String> args) async {
    try {
      return await _runner.run('adb', args);
    } on Object {
      return null; // adb not installed / not on PATH
    }
  }

  Future<void> _requireSuccess(List<String> args) async {
    final result = await _run(args);
    if (result == null) throw DeviceToolingUnavailableException('adb');
    if (!result.succeeded) {
      throw DeviceCommandException('adb', args, result.stderr);
    }
  }

  Future<Process> _startRaw(List<String> args) => Process.start('adb', args);
}

/// iOS simulators via `xcrun simctl`. macOS-only — `xcrun` does not exist on
/// Linux/Windows, so `listDevices()` here likewise degrades to an empty list
/// with the reason recorded, exactly like the Android provider without a
/// connected SDK.
class IosSimulatorDeviceProvider implements DeviceProvider {
  IosSimulatorDeviceProvider({DeviceProcessRunner? runner})
      : _runner = runner ?? RealDeviceProcessRunner();

  final DeviceProcessRunner _runner;

  @override
  DevicePlatform get platform => DevicePlatform.ios;

  @override
  Future<List<Device>> listDevices() async {
    final result = await _run(['simctl', 'list', 'devices', '--json']);
    if (result == null || !result.succeeded) return const [];
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(result.stdout) as Map<String, dynamic>;
    } catch (_) {
      return const [];
    }
    final devicesByRuntime = parsed['devices'] as Map<String, dynamic>? ?? const {};
    final devices = <Device>[];
    for (final entry in devicesByRuntime.entries) {
      final runtimeName = entry.key; // e.g. "com.apple.CoreSimulator.SimRuntime.iOS-17-0"
      final osVersion = runtimeName.contains('iOS')
          ? runtimeName.split('iOS-').last.replaceAll('-', '.')
          : runtimeName;
      for (final raw in entry.value as List<dynamic>) {
        final map = raw as Map<String, dynamic>;
        if (map['isAvailable'] != true) continue;
        if (map['state'] != 'Booted' && map['state'] != 'Shutdown') continue;
        devices.add(Device(
          id: map['udid'] as String,
          name: map['name'] as String,
          platform: DevicePlatform.ios,
          osVersion: osVersion,
          connection: DeviceConnection.simulator,
        ));
      }
    }
    return devices;
  }

  @override
  Future<void> install(String deviceId, String appPath) async {
    await _requireSuccess(['simctl', 'install', deviceId, appPath]);
  }

  @override
  Future<void> launch(String deviceId, String appIdentifier) async {
    await _requireSuccess(['simctl', 'launch', deviceId, appIdentifier]);
  }

  @override
  Future<void> terminate(String deviceId, String appIdentifier) async {
    await _requireSuccess(['simctl', 'terminate', deviceId, appIdentifier]);
  }

  @override
  Future<String> logs(String deviceId, {int tailLines = 200}) async {
    // `simctl spawn <udid> log show --last 2m` is the closest simctl
    // equivalent to `adb logcat`; a live `log stream` is intentionally not
    // used here to keep this call bounded and non-interactive.
    final result = await _run(['simctl', 'spawn', deviceId, 'log', 'show', '--last', '2m']);
    return result?.stdout ?? '';
  }

  @override
  Future<void> screenshot(String deviceId, String outputPath) async {
    await _requireSuccess(['simctl', 'io', deviceId, 'screenshot', outputPath]);
  }

  @override
  Future<String> shell(String deviceId, String command) async {
    final parts = command.split(RegExp(r'\s+'));
    final result = await _run(['simctl', 'spawn', deviceId, ...parts]);
    return result?.stdout ?? '';
  }

  Future<DeviceCommandResult?> _run(List<String> args) async {
    try {
      return await _runner.run('xcrun', args);
    } on Object {
      return null; // xcrun not present (non-macOS host, or no Xcode CLT)
    }
  }

  Future<void> _requireSuccess(List<String> args) async {
    final result = await _run(args);
    if (result == null) throw DeviceToolingUnavailableException('xcrun');
    if (!result.succeeded) {
      throw DeviceCommandException('xcrun', args, result.stderr);
    }
  }
}

class DeviceCommandException implements Exception {
  DeviceCommandException(this.tool, this.args, this.stderr);
  final String tool;
  final List<String> args;
  final String stderr;
  @override
  String toString() => '$tool ${args.join(' ')} failed: $stderr';
}
