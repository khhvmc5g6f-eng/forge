import 'dart:async';

import 'computer_control_driver.dart';

enum ComputerSessionState { running, paused, stopped }

/// Thrown by [ComputerControlSession.guarded] once the session has been
/// stopped — every in-flight and future action fails immediately rather
/// than silently continuing.
class ComputerControlStoppedException implements Exception {
  @override
  String toString() => 'Computer-use session was stopped.';
}

/// Wraps a [ComputerControlDriver] with the brief's required session
/// controls: "Display an obvious indicator whenever computer control is
/// active. Provide: PAUSE, STOP, EMERGENCY STOP." This class is the
/// pure-Dart, platform-independent part of computer-use — genuinely
/// testable regardless of whether a real [ComputerControlDriver] exists for
/// the host, because it never touches the driver except to forward an
/// already-decided-safe call through [guarded].
///
/// A caller (the UI, or the Computer-Use Agent's tool layer) is expected to
/// watch [stateStream] to render the "computer control is active" indicator
/// and expose Pause/Stop/Emergency Stop controls that call [pause]/[resume]/
/// [stop]/[emergencyStop] directly — this class does not render UI itself.
class ComputerControlSession {
  ComputerControlSession(this.driver);

  final ComputerControlDriver driver;

  ComputerSessionState _state = ComputerSessionState.running;
  ComputerSessionState get state => _state;

  final _stateController = StreamController<ComputerSessionState>.broadcast();
  Stream<ComputerSessionState> get stateStream => _stateController.stream;

  Completer<void>? _resumeSignal;

  void pause() {
    if (_state != ComputerSessionState.running) return;
    _state = ComputerSessionState.paused;
    _resumeSignal = Completer<void>();
    _stateController.add(_state);
  }

  void resume() {
    if (_state != ComputerSessionState.paused) return;
    _state = ComputerSessionState.running;
    _resumeSignal?.complete();
    _resumeSignal = null;
    _stateController.add(_state);
  }

  /// Stops the session permanently — it cannot be resumed. Any action
  /// currently blocked in [guarded] because the session was paused is
  /// released immediately and fails with [ComputerControlStoppedException].
  void stop() {
    if (_state == ComputerSessionState.stopped) return;
    _state = ComputerSessionState.stopped;
    if (_resumeSignal != null && !_resumeSignal!.isCompleted) {
      _resumeSignal!.complete();
    }
    _stateController.add(_state);
  }

  /// Identical to [stop] — kept as a distinct, unmistakably-named entry
  /// point for the brief's "EMERGENCY STOP" affordance, which a UI should
  /// wire to its most prominent, always-reachable control rather than
  /// nesting it behind the same menu as an ordinary pause.
  void emergencyStop() => stop();

  Future<void> dispose() async {
    await _stateController.close();
  }

  /// Runs [action] once the session is not paused, or throws
  /// [ComputerControlStoppedException] immediately if it has been stopped.
  /// Every computer-use tool call goes through this — see
  /// `computer_control_tools.dart`.
  Future<T> guarded<T>(Future<T> Function(ComputerControlDriver driver) action) async {
    if (_state == ComputerSessionState.stopped) {
      throw ComputerControlStoppedException();
    }
    if (_state == ComputerSessionState.paused) {
      await _resumeSignal!.future;
      if (_state == ComputerSessionState.stopped) {
        throw ComputerControlStoppedException();
      }
    }
    return action(driver);
  }
}
