import 'device.dart';
import 'device_provider.dart';

/// Aggregates every configured [DeviceProvider] (Android via `adb`, iOS via
/// `xcrun simctl`) behind one discovery/dispatch surface — the Devices
/// panel's data source, and what the Device Agent's tools call into.
class DeviceManager {
  DeviceManager({List<DeviceProvider>? providers})
      : _providers = providers ?? [AdbDeviceProvider(), IosSimulatorDeviceProvider()];

  final List<DeviceProvider> _providers;

  Future<List<Device>> discoverAll() async {
    final all = <Device>[];
    for (final provider in _providers) {
      all.addAll(await provider.listDevices());
    }
    return all;
  }

  DeviceProvider providerFor(DevicePlatform platform) =>
      _providers.firstWhere((p) => p.platform == platform);

  Future<Device?> find(String deviceId) async {
    for (final device in await discoverAll()) {
      if (device.id == deviceId) return device;
    }
    return null;
  }
}
