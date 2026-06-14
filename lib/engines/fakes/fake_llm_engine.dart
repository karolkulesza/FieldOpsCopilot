import '../llm_engine.dart';
import '../tool_schema.dart';

/// Deterministic, in-memory [LlmEngine] for unit tests and the skeleton UI.
///
/// Each call to [generate] consumes the next scripted "turn" (an ordered list
/// of [LlmEvent]s). This lets tests drive the exact token / tool-call sequence
/// an agent loop would see from a real model, with zero device dependency.
class FakeLlmEngine implements LlmEngine {
  FakeLlmEngine({List<List<LlmEvent>>? turns}) : _turns = [...?turns];

  final List<List<LlmEvent>> _turns;
  bool _ready = false;

  @override
  bool get isReady => _ready;

  /// Queues another scripted turn to be returned by a future [generate] call.
  void enqueue(List<LlmEvent> events) => _turns.add(events);

  @override
  Future<void> initialize() async {
    _ready = true;
  }

  /// Both guards are checked **synchronously**, before any stream is returned, which is
  /// why this is not itself an `async*` body: an `async*` generator defers everything
  /// to the first listen, so a caller would get an error on the stream instead of at
  /// the call site. `GemmaLlmEngine.generate` throws at the call site, and a fake whose
  /// *failure mode* differs from the real engine's is the same trap as one whose rules
  /// differ — code written against the fake would handle the wrong thing.
  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) {
    if (!_ready) {
      throw StateError('FakeLlmEngine.generate called before initialize()');
    }
    // The fake enforces the tool-schema contract too, and that is the whole point of
    // it. Task 1.9's agent loop and Task 1.10's golden suite are unit-tested against
    // this class; if it accepted a malformed schema that the device engine throws on,
    // a tool registry could pass every host test and fail on the demo device at 1.11.
    // A fake that is more permissive than the thing it stands in for is not a fake, it
    // is a trap.
    assertToolDefinitionsUsable(tools);
    return _replayNextTurn();
  }

  Stream<LlmEvent> _replayNextTurn() async* {
    final events = _turns.isNotEmpty ? _turns.removeAt(0) : const <LlmEvent>[];
    for (final event in events) {
      yield event;
    }
  }

  @override
  Future<void> dispose() async {
    _ready = false;
    _turns.clear();
  }
}
