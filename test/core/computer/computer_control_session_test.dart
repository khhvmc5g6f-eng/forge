import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/computer/computer_control_session.dart';
import 'package:forge/core/computer/fake_computer_control_driver.dart';

void main() {
  late FakeComputerControlDriver driver;
  late ComputerControlSession session;

  setUp(() {
    driver = FakeComputerControlDriver();
    session = ComputerControlSession(driver);
  });

  tearDown(() => session.dispose());

  test('guarded() runs the action immediately while running', () async {
    await session.guarded((d) => d.typeText('hello'));
    expect(driver.typedText, 'hello');
  });

  test('pause() blocks guarded() until resume() is called', () async {
    session.pause();
    expect(session.state, ComputerSessionState.paused);

    var completed = false;
    final future = session.guarded((d) => d.typeText('x')).then((_) => completed = true);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(completed, isFalse, reason: 'action must not run while paused');

    session.resume();
    await future;
    expect(completed, isTrue);
    expect(driver.typedText, 'x');
  });

  test('stop() releases a paused action with ComputerControlStoppedException', () async {
    session.pause();
    final future = session.guarded((d) => d.typeText('never'));

    session.stop();

    await expectLater(future, throwsA(isA<ComputerControlStoppedException>()));
    expect(driver.typedText, isEmpty);
  });

  test('guarded() throws immediately once stopped, without calling the driver', () async {
    session.stop();
    expect(
      () => session.guarded((d) => d.typeText('unreachable')),
      throwsA(isA<ComputerControlStoppedException>()),
    );
    expect(driver.typedText, isEmpty);
  });

  test('emergencyStop() behaves identically to stop() and is not resumable', () async {
    session.emergencyStop();
    expect(session.state, ComputerSessionState.stopped);
    session.resume(); // must be a no-op — stopped is terminal
    expect(session.state, ComputerSessionState.stopped);
  });

  test('stateStream emits every transition', () async {
    final states = <ComputerSessionState>[];
    final sub = session.stateStream.listen(states.add);

    session.pause();
    session.resume();
    session.stop();
    await Future<void>.delayed(Duration.zero);

    expect(states, [
      ComputerSessionState.paused,
      ComputerSessionState.running,
      ComputerSessionState.stopped,
    ]);
    await sub.cancel();
  });

  test('pause() and stop() are no-ops when not in the applicable state', () {
    session.stop();
    session.pause(); // already stopped — must not resurrect to paused
    expect(session.state, ComputerSessionState.stopped);
  });
}
