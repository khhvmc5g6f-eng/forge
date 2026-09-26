import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/devices/device.dart';
import 'package:forge/core/devices/device_manager.dart';
import 'package:forge/core/devices/device_process_runner.dart';
import 'package:forge/core/devices/device_provider.dart';

class _ScriptedRunner implements DeviceProcessRunner {
  final Map<String, DeviceCommandResult> _byArgs = {};
  final List<List<String>> calls = [];
  Object? throwFor;

  void whenArgs(List<String> args, DeviceCommandResult result) {
    _byArgs[args.join(' ')] = result;
  }

  @override
  Future<DeviceCommandResult> run(String executable, List<String> args) async {
    calls.add(args);
    if (throwFor != null) throw throwFor!;
    return _byArgs[args.join(' ')] ??
        const DeviceCommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

DeviceCommandResult ok(String stdout) =>
    DeviceCommandResult(exitCode: 0, stdout: stdout, stderr: '');

void main() {
  group('AdbDeviceProvider', () {
    test('parses `adb devices -l` output into Device objects', () async {
      final runner = _ScriptedRunner()
        ..whenArgs(
          ['devices', '-l'],
          ok('List of devices attached\n'
              'emulator-5554  device product:sdk_gphone64_arm64 model:Pixel_7 device:emu64a transport_id:1\n'
              'ABCD1234       unauthorized usb:1-1 transport_id:2\n'),
        );
      final provider = AdbDeviceProvider(runner: runner);
      final devices = await provider.listDevices();

      expect(devices, hasLength(1));
      expect(devices.first.id, 'emulator-5554');
      expect(devices.first.connection, DeviceConnection.emulator);
      expect(devices.first.name, 'Pixel 7');
    });

    test('listDevices returns empty list (not an exception) when adb is missing', () async {
      final runner = _ScriptedRunner()..throwFor = Exception('adb: command not found');
      final provider = AdbDeviceProvider(runner: runner);
      expect(await provider.listDevices(), isEmpty);
    });

    test('launch uses `am start` for an explicit component and monkey for a bare package', () async {
      final runner = _ScriptedRunner();
      final provider = AdbDeviceProvider(runner: runner);

      await provider.launch('dev1', 'com.example/.MainActivity');
      expect(runner.calls.last, ['-s', 'dev1', 'shell', 'am', 'start', '-n', 'com.example/.MainActivity']);

      await provider.launch('dev1', 'com.example');
      expect(
        runner.calls.last,
        ['-s', 'dev1', 'shell', 'monkey', '-p', 'com.example', '-c', 'android.intent.category.LAUNCHER', '1'],
      );
    });

    test('install throws DeviceCommandException on a non-zero exit code', () async {
      final runner = _ScriptedRunner()
        ..whenArgs(['-s', 'dev1', 'install', '-r', '/tmp/app.apk'],
            const DeviceCommandResult(exitCode: 1, stdout: '', stderr: 'INSTALL_FAILED'));
      final provider = AdbDeviceProvider(runner: runner);
      expect(
        () => provider.install('dev1', '/tmp/app.apk'),
        throwsA(isA<DeviceCommandException>()),
      );
    });
  });

  group('IosSimulatorDeviceProvider', () {
    test('parses `simctl list devices --json` into available Devices only', () async {
      final json = '''
      {
        "devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
            {"udid": "AAAA", "name": "iPhone 15", "isAvailable": true, "state": "Booted"},
            {"udid": "BBBB", "name": "Old Unavailable", "isAvailable": false, "state": "Shutdown"}
          ]
        }
      }
      ''';
      final runner = _ScriptedRunner()
        ..whenArgs(['simctl', 'list', 'devices', '--json'], ok(json));
      final provider = IosSimulatorDeviceProvider(runner: runner);
      final devices = await provider.listDevices();

      expect(devices, hasLength(1));
      expect(devices.first.id, 'AAAA');
      expect(devices.first.osVersion, '17.0');
      expect(devices.first.connection, DeviceConnection.simulator);
    });

    test('listDevices returns empty list when xcrun is missing (non-macOS host)', () async {
      final runner = _ScriptedRunner()..throwFor = Exception('xcrun: command not found');
      final provider = IosSimulatorDeviceProvider(runner: runner);
      expect(await provider.listDevices(), isEmpty);
    });
  });

  group('DeviceManager', () {
    test('discoverAll aggregates devices from every provider', () async {
      final androidRunner = _ScriptedRunner()
        ..whenArgs(['devices', '-l'],
            ok('List of devices attached\nemulator-5554  device model:Pixel_7\n'));
      final iosRunner = _ScriptedRunner()
        ..whenArgs(['simctl', 'list', 'devices', '--json'], ok('{"devices": {}}'));

      final manager = DeviceManager(providers: [
        AdbDeviceProvider(runner: androidRunner),
        IosSimulatorDeviceProvider(runner: iosRunner),
      ]);

      final devices = await manager.discoverAll();
      expect(devices, hasLength(1));
      expect(devices.first.platform, DevicePlatform.android);
    });
  });
}
