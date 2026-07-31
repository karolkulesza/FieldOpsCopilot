import '../llm_engine.dart';
import '../tool_schema.dart';

/// Deterministic, in-memory [LlmEngine] for unit tests and the skeleton UI.
///
/// Each call to [generate] consumes the next scripted "turn" (an ordered list
/// of [LlmEvent]s). This lets tests drive the exact token / tool-call sequence
/// an agent loop would see from a real model, with zero device dependency.
///
/// **It is deliberately no more permissive than the device engine.** Every rule
/// `GemmaLlmEngine` enforces is enforced here, at the same moment, with the same kind of
/// error: the tool-schema contract, one turn at a time, and no revival after disposal.
/// The reason is structural rather than tidy — Task 1.9's agent loop and Task 1.10's
/// golden suite are unit-tested against *this* class, so anything the fake tolerates and
/// the device refuses is a defect that passes the whole host suite and surfaces on the
/// demo device at 1.11. A fake that is easier to satisfy than the thing it stands in for
/// is not a fake, it is a trap.
class FakeLlmEngine implements LlmEngine {
  FakeLlmEngine({List<List<LlmEvent>>? turns}) : _turns = [...?turns];

  final List<List<LlmEvent>> _turns;
  bool _ready = false;
  bool _disposed = false;

  /// Whether a turn's stream has been handed out and not yet finished.
  ///
  /// Held from [generate] until the returned stream completes or is cancelled. **This is
  /// one place the fake is deliberately *stricter* than the device engine, and the
  /// divergence is worth stating rather than papering over.** `IsolateInferenceHost`
  /// subscribes to its own port unconditionally, so a turn nobody listened to is still
  /// released when the worker finishes it; the fake holds the slot until *someone drains
  /// the stream*, forever if nobody does.
  ///
  /// Perfect parity is not available here, because the fake's turn is instantaneous while
  /// the device's takes seconds. Releasing the slot as eagerly as the device does would
  /// mean it was never held by the time [generate] returned — and the guard would then be
  /// unable to catch the one thing it exists for. To be exact about which case that is,
  /// since it is the decisive argument: a microtask-deferred release would still catch two
  /// *synchronously* consecutive calls, but not two separated by an `await` — which is
  /// precisely how an agent loop is written. That is the direction that matters, because a
  /// permissive fake lets such a loop pass on the host and throw on device, which is the
  /// trap this whole contract exists to close. Erring strict costs a cheap false failure;
  /// erring eager ships a defect to Task 1.11. Dart also cannot detect a stream that will
  /// never be subscribed, so a consumer that asks for a turn and abandons it without
  /// cancelling is surfaced here, where it is cheap to find.
  bool _turnInFlight = false;

  @override
  bool get isReady => _ready;

  /// Queues another scripted turn to be returned by a future [generate] call.
  void enqueue(List<LlmEvent> events) => _turns.add(events);

  @override
  Future<void> initialize() async {
    if (_disposed) {
      // `GemmaLlmEngine` refuses this: its isolate is gone and its host will not
      // restart. A fake that quietly revived would let a lifecycle bug pass the host
      // suite.
      throw StateError('FakeLlmEngine was disposed; create a new instance');
    }
    _ready = true;
  }

  /// Every guard is checked **synchronously**, before any stream is returned, which is
  /// why this is not itself an `async*` body: an `async*` generator defers its whole body
  /// to the first listen, so a caller would get an error on the stream instead of at the
  /// call site. `GemmaLlmEngine.generate` throws at the call site, and a fake whose
  /// *failure timing* differs from the real engine's is the same trap as one whose rules
  /// differ — code written against the fake would handle the wrong thing.
  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) {
    if (_disposed) {
      throw StateError('FakeLlmEngine was disposed');
    }
    if (!_ready) {
      throw StateError('FakeLlmEngine.generate called before initialize()');
    }
    if (_turnInFlight) {
      // The device engine refuses this because inference is serialised all the way down
      // — one native conversation at a time — so an agent loop that overlapped turns
      // would work here and fail there.
      throw StateError('a generation turn is already in flight');
    }
    assertToolDefinitionsUsable(tools);
    _turnInFlight = true;
    return _replayNextTurn();
  }

  Stream<LlmEvent> _replayNextTurn() async* {
    try {
      final events = _turns.isNotEmpty
          ? _turns.removeAt(0)
          : const <LlmEvent>[];
      for (final event in events) {
        yield event;
      }
    } finally {
      // Runs on normal completion *and* on cancellation, which is what makes a
      // subsequent turn possible after a consumer walks away mid-stream.
      _turnInFlight = false;
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _ready = false;
    _turnInFlight = false;
    _turns.clear();
  }
}
