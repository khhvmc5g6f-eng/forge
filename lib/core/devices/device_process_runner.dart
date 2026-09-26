import 'dart:io';

/// The exact same "inject the process runner" pattern as
/// `lib/core/git/git_service.dart`'s `ProcessRunner`, duplicated (rather
/// than shared) so `AdbDeviceProvider`/`IosSimulatorDeviceProvider` don't
/// take a dependency on the Git module for an unrelated concern. Both are
/// small, stable interfaces; keeping them independent avoids coupling two
/// otherwise-unrelated subsystems just to save a few lines.
abstract class DeviceProcessRunner {
  Future<DeviceCommandResult> run(String executable, List<String> args);
}

class DeviceCommandResult {
  const DeviceCommandResult({required this.exitCode, required this.stdout, required this.stderr});
  final int exitCode;
  final String stdout;
  final String stderr;
  bool get succeeded => exitCode == 0;
}

class RealDeviceProcessRunner implements DeviceProcessRunner {
  @override
  Future<DeviceCommandResult> run(String executable, List<String> args) async {
    final result = await Process.run(executable, args);
    return DeviceCommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  }
}
