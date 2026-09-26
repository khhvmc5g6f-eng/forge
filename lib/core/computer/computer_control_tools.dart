import 'dart:convert';

import '../security/untrusted_content.dart';
import '../tools/policy_engine.dart';
import '../tools/tool.dart';
import '../tools/tool_category.dart';
import 'computer_control_driver.dart';
import 'computer_control_session.dart';

abstract class _ComputerTool implements Tool {
  _ComputerTool(this.session);
  final ComputerControlSession session;

  @override
  ToolCategory get category => ToolCategory.computer;

  @override
  ToolInvocation describeInvocation(Map<String, dynamic> arguments) =>
      ToolInvocation(category: category, toolName: name, description: '$name($arguments)');
}

class ListAccessibleElementsTool extends _ComputerTool {
  ListAccessibleElementsTool(super.session);
  @override
  String get name => 'list_accessible_elements';
  @override
  String get description =>
      'Lists on-screen elements via the accessibility tree — always call this '
      'before click_element, and prefer it over capture_screen for deciding '
      'what to interact with.';
  @override
  Map<String, dynamic> get parametersSchema => const {'type': 'object', 'properties': {}};
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final elements = await session.guarded((driver) => driver.listAccessibleElements());
    final body = elements
        .map((e) => jsonEncode({
              'id': e.id,
              'role': e.role,
              'label': e.label,
              'x': e.x,
              'y': e.y,
              'width': e.width,
              'height': e.height,
            }))
        .join('\n');
    return UntrustedContent(source: ContentSource.toolResult, body: body);
  }
}

class ClickElementTool extends _ComputerTool {
  ClickElementTool(super.session);
  @override
  String get name => 'click_element';
  @override
  String get description =>
      'Clicks an element by its accessibility-tree id (from list_accessible_elements).';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'element_id': {'type': 'string'},
        },
        'required': ['element_id'],
      };
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    await session.guarded((driver) => driver.clickElement(arguments['element_id'] as String));
    return const UntrustedContent(source: ContentSource.toolResult, body: 'Clicked');
  }
}

class ClickAtTool extends _ComputerTool {
  ClickAtTool(super.session);
  @override
  String get name => 'click_at';
  @override
  String get description =>
      'Clicks a raw (x, y) screen coordinate. Fallback only — prefer click_element '
      'when an accessible element exists for the target.';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'x': {'type': 'number'},
          'y': {'type': 'number'},
        },
        'required': ['x', 'y'],
      };
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final point = ScreenPoint((arguments['x'] as num).toDouble(), (arguments['y'] as num).toDouble());
    await session.guarded((driver) => driver.clickAt(point));
    return const UntrustedContent(source: ContentSource.toolResult, body: 'Clicked');
  }
}

class TypeTextTool extends _ComputerTool {
  TypeTextTool(super.session);
  @override
  String get name => 'computer_type_text';
  @override
  String get description => 'Types text into the currently focused element.';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
      };
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    await session.guarded((driver) => driver.typeText(arguments['text'] as String));
    return const UntrustedContent(source: ContentSource.toolResult, body: 'Typed');
  }
}

class PressKeyTool extends _ComputerTool {
  PressKeyTool(super.session);
  @override
  String get name => 'computer_press_key';
  @override
  String get description => 'Presses a single key or key combination (e.g. "Return", "Cmd+A").';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'key': {'type': 'string'},
        },
        'required': ['key'],
      };
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    await session.guarded((driver) => driver.pressKey(arguments['key'] as String));
    return const UntrustedContent(source: ContentSource.toolResult, body: 'Pressed');
  }
}

class CaptureScreenTool extends _ComputerTool {
  CaptureScreenTool(super.session);
  @override
  String get name => 'capture_screen';
  @override
  String get description =>
      'Captures the current screen as PNG bytes (base64-encoded). Use only when no '
      'accessible element exists to answer the question — prefer '
      'list_accessible_elements for taking actions, per the accessibility-first policy.';
  @override
  Map<String, dynamic> get parametersSchema => const {'type': 'object', 'properties': {}};
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final bytes = await session.guarded((driver) => driver.captureScreen());
    return UntrustedContent(source: ContentSource.toolResult, body: base64Encode(bytes));
  }
}

void registerComputerControlTools(void Function(Tool) register, ComputerControlSession session) {
  register(ListAccessibleElementsTool(session));
  register(ClickElementTool(session));
  register(ClickAtTool(session));
  register(TypeTextTool(session));
  register(PressKeyTool(session));
  register(CaptureScreenTool(session));
}
