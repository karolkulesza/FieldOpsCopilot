import '../llm_engine.dart';

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

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) async* {
    if (!_ready) {
      throw StateError('FakeLlmEngine.generate called before initialize()');
    }
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
