import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/computer/computer_control_driver.dart';
import 'package:forge/core/computer/computer_control_session.dart';
import 'package:forge/core/computer/computer_control_tools.dart';
import 'package:forge/core/computer/fake_computer_control_driver.dart';
import 'package:forge/core/tools/policy_engine.dart';
import 'package:forge/core/tools/tool.dart';
import 'package:forge/core/tools/tool_category.dart';

void main() {
  late FakeComputerControlDriver driver;
  late ComputerControlSession session;
  late ToolGateway gateway;

  setUp(() {
    driver = FakeComputerControlDriver();
    session = ComputerControlSession(driver);
    gateway = ToolGateway(
      policyEngine: PolicyEngine(
        mode: OperatingMode.autonomous,
        grantedLevel: PermissionLevel.controlTestDevice,
        projectRoot: '/repo',
      ),
    );
    registerComputerControlTools(gateway.register, session);
  });

  tearDown(() => session.dispose());

  test('list_accessible_elements returns elements from the driver', () async {
    driver.elements = const [
      AccessibilityElement(id: 'btn1', role: 'button', label: 'Submit', x: 0, y: 0, width: 10, height: 10),
    ];
    final result = await gateway.invoke('list_accessible_elements', {});
    expect(result.body, contains('Submit'));
  });

  test('click_element clicks a real discovered element id', () async {
    driver.elements = const [
      AccessibilityElement(id: 'btn1', role: 'button', label: 'Submit', x: 0, y: 0, width: 10, height: 10),
    ];
    await gateway.invoke('click_element', {'element_id': 'btn1'});
    expect(driver.actionsLog, contains('clickElement(btn1)'));
  });

  test('computer tools require Control Test Device permission', () async {
    final restrictedGateway = ToolGateway(
      policyEngine: PolicyEngine(
        mode: OperatingMode.autonomous,
        grantedLevel: PermissionLevel.editProject, // below controlTestDevice
        projectRoot: '/repo',
      ),
      onApprovalNeeded: (invocation, reason) async => false, // simulate user declining
    );
    registerComputerControlTools(restrictedGateway.register, session);

    expect(
      () => restrictedGateway.invoke('computer_type_text', {'text': 'x'}),
      throwsA(isA<ToolDeniedException>()),
    );
  });

  test('a stopped session denies computer tool execution even with full permission', () async {
    session.stop();
    expect(
      () => gateway.invoke('computer_press_key', {'key': 'Return'}),
      throwsA(isA<ComputerControlStoppedException>()),
    );
  });
}
