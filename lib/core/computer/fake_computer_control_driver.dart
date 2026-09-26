import 'computer_control_driver.dart';

/// An in-memory, fully-simulated [ComputerControlDriver] — exercises the
/// full tool/session/policy pipeline in tests on any platform, standing in
/// for the macOS-only `MacosAccessibilityDriver` this container cannot run.
class FakeComputerControlDriver implements ComputerControlDriver {
  final List<String> actionsLog = [];
  List<AccessibilityElement> elements = const [];
  String typedText = '';
  final List<String> pressedKeys = [];

  @override
  Future<List<int>> captureScreen() async {
    actionsLog.add('captureScreen');
    return const [0x89, 0x50, 0x4E, 0x47]; // PNG magic bytes, as a stand-in
  }

  @override
  Future<List<AccessibilityElement>> listAccessibleElements() async {
    actionsLog.add('listAccessibleElements');
    return elements;
  }

  @override
  Future<void> clickElement(String elementId) async {
    if (elements.every((e) => e.id != elementId)) {
      throw ArgumentError('No such element: $elementId');
    }
    actionsLog.add('clickElement($elementId)');
  }

  @override
  Future<void> clickAt(ScreenPoint point) async {
    actionsLog.add('clickAt(${point.x}, ${point.y})');
  }

  @override
  Future<void> typeText(String text) async {
    typedText += text;
    actionsLog.add('typeText($text)');
  }

  @override
  Future<void> pressKey(String key) async {
    pressedKeys.add(key);
    actionsLog.add('pressKey($key)');
  }
}
