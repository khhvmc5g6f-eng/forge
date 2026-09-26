import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/devices/device.dart';

final deviceListProvider = FutureProvider.autoDispose<List<Device>>((ref) async {
  return ref.watch(deviceManagerProvider).discoverAll();
});

/// The Devices section: real `adb`/`xcrun simctl` discovery
/// (`lib/core/devices/`), not mock data — on a host without the Android SDK
/// or Xcode installed (like this development container) it correctly shows
/// zero devices rather than fabricating any, per `DEVELOPMENT.md`.
class DevicesPanel extends ConsumerWidget {
  const DevicesPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devicesAsync = ref.watch(deviceListProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => ref.invalidate(deviceListProvider),
        child: const Icon(Icons.refresh),
      ),
      body: devicesAsync.when(
        data: (devices) => devices.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No devices found.\n\n'
                    'Android devices require the Android SDK platform-tools (`adb`) on PATH; '
                    'iOS simulators require Xcode (`xcrun simctl`) on a macOS host. '
                    'Neither is installed in this environment.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.builder(
                itemCount: devices.length,
                itemBuilder: (context, index) {
                  final device = devices[index];
                  return ListTile(
                    leading: Icon(
                      device.platform == DevicePlatform.android
                          ? Icons.android
                          : Icons.phone_iphone,
                    ),
                    title: Text(device.name),
                    subtitle: Text('${device.id} · ${device.osVersion} · ${device.connection.name}'),
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('$e')),
      ),
    );
  }
}
