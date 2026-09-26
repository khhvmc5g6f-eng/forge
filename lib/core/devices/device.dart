enum DevicePlatform { android, ios }

enum DeviceConnection { usb, wifi, emulator, simulator }

class Device {
  const Device({
    required this.id,
    required this.name,
    required this.platform,
    required this.osVersion,
    required this.connection,
  });

  final String id;
  final String name;
  final DevicePlatform platform;
  final String osVersion;
  final DeviceConnection connection;

  @override
  String toString() => '$name ($id, $osVersion, ${connection.name})';
}

/// Thrown when a device-tooling binary (`adb`, `xcrun`) is not on `PATH` for
/// this host — expected and non-fatal in a container with no Android SDK or
/// Xcode installed; callers surface this as "no devices" rather than
/// crashing.
class DeviceToolingUnavailableException implements Exception {
  DeviceToolingUnavailableException(this.tool);
  final String tool;
  @override
  String toString() => '$tool is not installed or not on PATH.';
}
