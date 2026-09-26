/// One element from a semantic accessibility-tree query — the brief is
/// explicit that computer-use should "prefer semantic APIs/accessibility
/// information before coordinate-based clicking," so [ComputerControlDriver]
/// exposes element-based interaction as the primary path and a raw-pixel
/// coordinate fallback only for when no accessible element exists.
class AccessibilityElement {
  const AccessibilityElement({
    required this.id,
    required this.role,
    required this.label,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final String id;
  final String role;
  final String label;
  final double x;
  final double y;
  final double width;
  final double height;
}

/// A single (x, y) point in screen coordinates — the fallback path used only
/// when [ComputerControlDriver.listAccessibleElements] has no matching
/// element for what needs clicking.
class ScreenPoint {
  const ScreenPoint(this.x, this.y);
  final double x;
  final double y;
}

/// Platform-level screen/input control. `MacosAccessibilityDriver` is the
/// only production implementation intended for Forge (macOS is the target
/// platform per the brief); it requires native Accessibility API access via
/// a Flutter macOS platform channel that cannot be built or exercised in
/// this development container (no macOS host, no display). `FakeComputerControlDriver`
/// exercises the full tool/session/policy pipeline in tests without needing
/// real screen access on any platform.
abstract class ComputerControlDriver {
  Future<List<int>> captureScreen();
  Future<List<AccessibilityElement>> listAccessibleElements();
  Future<void> clickElement(String elementId);
  Future<void> clickAt(ScreenPoint point);
  Future<void> typeText(String text);
  Future<void> pressKey(String key);
}

/// Documents the real integration point rather than faking one. Every
/// method throws immediately with a message pointing at what macOS API work
/// remains (see `lib/core/security/secrets_store.dart`'s
/// `KeychainSecretsStore` for the same documented-stub pattern used
/// elsewhere in this codebase for platform capabilities this container
/// cannot provide).
class MacosAccessibilityDriver implements ComputerControlDriver {
  static const _reason =
      'Computer-use requires the macOS Accessibility API (AXUIElement) via a '
      'Flutter macOS platform channel (Swift, using the ApplicationServices '
      'framework) plus the Accessibility permission grant in System '
      'Settings. This cannot be implemented or verified without a real '
      'macOS host — see DEVELOPMENT.md for the integration plan.';

  @override
  Future<List<int>> captureScreen() => throw UnimplementedError(_reason);

  @override
  Future<List<AccessibilityElement>> listAccessibleElements() =>
      throw UnimplementedError(_reason);

  @override
  Future<void> clickElement(String elementId) => throw UnimplementedError(_reason);

  @override
  Future<void> clickAt(ScreenPoint point) => throw UnimplementedError(_reason);

  @override
  Future<void> typeText(String text) => throw UnimplementedError(_reason);

  @override
  Future<void> pressKey(String key) => throw UnimplementedError(_reason);
}
