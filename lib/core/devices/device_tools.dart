import '../security/untrusted_content.dart';
import '../tools/policy_engine.dart';
import '../tools/tool.dart';
import '../tools/tool_category.dart';
import 'device_manager.dart';

abstract class _DeviceTool implements Tool {
  _DeviceTool(this.manager);
  final DeviceManager manager;

  @override
  ToolCategory get category => ToolCategory.device;

  @override
  ToolInvocation describeInvocation(Map<String, dynamic> arguments) => ToolInvocation(
        category: category,
        toolName: name,
        description: '$name(${arguments['device_id'] ?? ''})',
      );
}

class ListDevicesTool extends _DeviceTool {
  ListDevicesTool(super.manager);
  @override
  String get name => 'list_devices';
  @override
  String get description => 'Discovers connected Android (adb) and iOS Simulator devices.';
  @override
  Map<String, dynamic> get parametersSchema => const {'type': 'object', 'properties': {}};
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final devices = await manager.discoverAll();
    final body = devices.isEmpty
        ? 'No devices found (no adb/xcrun tooling available, or none connected).'
        : devices.map((d) => d.toString()).join('\n');
    return UntrustedContent(source: ContentSource.toolResult, body: body);
  }
}

class InstallAppTool extends _DeviceTool {
  InstallAppTool(super.manager);
  @override
  String get name => 'install_app';
  @override
  String get description => 'Installs a build (.apk or .app) onto a device.';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'device_id': {'type': 'string'},
          'app_path': {'type': 'string'},
        },
        'required': ['device_id', 'app_path'],
      };
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final device = await manager.find(arguments['device_id'] as String);
    if (device == null) {
      return const UntrustedContent(source: ContentSource.toolResult, body: 'ERROR: device not found');
    }
    await manager.providerFor(device.platform).install(device.id, arguments['app_path'] as String);
    return const UntrustedContent(source: ContentSource.toolResult, body: 'Installed');
  }
}

class LaunchAppTool extends _DeviceTool {
  LaunchAppTool(super.manager);
  @override
  String get name => 'launch_app';
  @override
  String get description => 'Launches an app on a device (package/bundle identifier).';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'device_id': {'type': 'string'},
          'app_identifier': {'type': 'string'},
        },
        'required': ['device_id', 'app_identifier'],
      };
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final device = await manager.find(arguments['device_id'] as String);
    if (device == null) {
      return const UntrustedContent(source: ContentSource.toolResult, body: 'ERROR: device not found');
    }
    await manager
        .providerFor(device.platform)
        .launch(device.id, arguments['app_identifier'] as String);
    return const UntrustedContent(source: ContentSource.toolResult, body: 'Launched');
  }
}

class DeviceLogsTool extends _DeviceTool {
  DeviceLogsTool(super.manager);
  @override
  String get name => 'device_logs';
  @override
  String get description => 'Reads recent logs from a device.';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'device_id': {'type': 'string'},
        },
        'required': ['device_id'],
      };
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final device = await manager.find(arguments['device_id'] as String);
    if (device == null) {
      return const UntrustedContent(source: ContentSource.toolResult, body: 'ERROR: device not found');
    }
    final logs = await manager.providerFor(device.platform).logs(device.id);
    return UntrustedContent(source: ContentSource.toolResult, body: logs);
  }
}

class DeviceScreenshotTool extends _DeviceTool {
  DeviceScreenshotTool(super.manager);
  @override
  String get name => 'device_screenshot';
  @override
  String get description => 'Captures a screenshot from a device to a file path.';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'device_id': {'type': 'string'},
          'output_path': {'type': 'string'},
        },
        'required': ['device_id', 'output_path'],
      };

  @override
  ToolInvocation describeInvocation(Map<String, dynamic> arguments) => ToolInvocation(
        category: category,
        toolName: name,
        targetPath: arguments['output_path'] as String?,
        description: '$name(${arguments['device_id']})',
      );

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final device = await manager.find(arguments['device_id'] as String);
    if (device == null) {
      return const UntrustedContent(source: ContentSource.toolResult, body: 'ERROR: device not found');
    }
    await manager
        .providerFor(device.platform)
        .screenshot(device.id, arguments['output_path'] as String);
    return UntrustedContent(
        source: ContentSource.toolResult, body: 'Saved to ${arguments['output_path']}');
  }
}

void registerDeviceTools(void Function(Tool) register, DeviceManager manager) {
  register(ListDevicesTool(manager));
  register(InstallAppTool(manager));
  register(LaunchAppTool(manager));
  register(DeviceLogsTool(manager));
  register(DeviceScreenshotTool(manager));
}
