/// The message vocabulary spoken across the inference isolate boundary.
///
/// Requests and replies are encoded as plain maps of JSON-compatible values even
/// though Dart can copy most objects between isolates in the same group. That is a
/// deliberate cost: an explicit codec is *testable on the host*, so the encoding
/// the device depends on is exercised by unit tests that never spawn an isolate,
/// and a change to `LlmEvent` cannot silently alter what crosses the port.
///
/// [SendPort]s are the one thing that never goes through this codec — they are not
/// JSON, and a codec that had to carry them could not be round-tripped in a test.
/// The transport pairs each encoded request with its reply port as a two-element
/// list instead; see `inference_isolate.dart`.
library;

import '../../engines/llm_engine.dart';

/// Wire key naming the variant of a request or reply.
const String kindKey = 'kind';

/// A request sent from the app to the inference worker.
sealed class InferenceRequest {
  const InferenceRequest();

  Map<String, Object?> toWire();

  /// Decodes a request, throwing [FormatException] on anything unrecognised.
  static InferenceRequest fromWire(Map<String, Object?> wire) {
    final kind = wire[kindKey];
    return switch (kind) {
      LoadRequest.kind => LoadRequest.fromWire(wire),
      GenerateRequest.kind => GenerateRequest.fromWire(wire),
      StopRequest.kind => StopRequest.fromWire(wire),
      ShutdownRequest.kind => const ShutdownRequest(),
      _ => throw FormatException('unknown inference request "$kind"'),
    };
  }
}

/// Load the weights and make the engine ready. Answered with [LoadedReply] or
/// [FailureReply].
final class LoadRequest extends InferenceRequest {
  const LoadRequest(this.config);

  static const String kind = 'load';

  final InferenceConfigWire config;

  @override
  Map<String, Object?> toWire() => {kindKey: kind, 'config': config};

  static LoadRequest fromWire(Map<String, Object?> wire) {
    final config = wire['config'];
    if (config is! Map) {
      throw const FormatException('load request: missing config');
    }
    return LoadRequest(config.cast<String, Object?>());
  }
}

/// Run one generation turn. Answered with a series of [EventReply]s terminated by
/// an `LlmDone` event, or by a [FailureReply].
final class GenerateRequest extends InferenceRequest {
  const GenerateRequest({
    required this.turnId,
    required this.prompt,
    this.tools = const [],
  });

  static const String kind = 'generate';

  /// Monotonic id of this turn.
  ///
  /// Carried so a late [StopRequest] can be recognised as stale. Without it, a
  /// stop arriving just after turn N finished would cancel turn N+1 — a race the
  /// user experiences as "the second question got no answer".
  final int turnId;

  final String prompt;
  final List<ToolDefinition> tools;

  @override
  Map<String, Object?> toWire() => {
    kindKey: kind,
    'turnId': turnId,
    'prompt': prompt,
    'tools': [for (final tool in tools) encodeToolDefinition(tool)],
  };

  static GenerateRequest fromWire(Map<String, Object?> wire) {
    final turnId = wire['turnId'];
    final prompt = wire['prompt'];
    final tools = wire['tools'];
    if (turnId is! int) {
      throw const FormatException('generate request: missing turnId');
    }
    if (prompt is! String) {
      throw const FormatException('generate request: missing prompt');
    }
    if (tools is! List) {
      throw const FormatException('generate request: tools must be a list');
    }
    return GenerateRequest(
      turnId: turnId,
      prompt: prompt,
      tools: [
        for (final tool in tools)
          decodeToolDefinition((tool as Map).cast<String, Object?>()),
      ],
    );
  }
}

/// Ask the worker to stop generating [turnId]. Not itself acknowledged: the turn's
/// own event stream closing is the acknowledgement.
final class StopRequest extends InferenceRequest {
  const StopRequest(this.turnId);

  static const String kind = 'stop';

  final int turnId;

  @override
  Map<String, Object?> toWire() => {kindKey: kind, 'turnId': turnId};

  static StopRequest fromWire(Map<String, Object?> wire) {
    final turnId = wire['turnId'];
    if (turnId is! int) {
      throw const FormatException('stop request: missing turnId');
    }
    return StopRequest(turnId);
  }
}

/// Close the model and let the isolate exit. Answered with [ShutdownReply].
final class ShutdownRequest extends InferenceRequest {
  const ShutdownRequest();

  static const String kind = 'shutdown';

  @override
  Map<String, Object?> toWire() => {kindKey: kind};
}

/// A message sent from the inference worker back to the app.
sealed class InferenceReply {
  const InferenceReply();

  Map<String, Object?> toWire();

  static InferenceReply fromWire(Map<String, Object?> wire) {
    final kind = wire[kindKey];
    return switch (kind) {
      LoadedReply.kind => LoadedReply.fromWire(wire),
      EventReply.kind => EventReply.fromWire(wire),
      FailureReply.kind => FailureReply.fromWire(wire),
      ShutdownReply.kind => const ShutdownReply(),
      _ => throw FormatException('unknown inference reply "$kind"'),
    };
  }
}

/// The engine is loaded and ready, with the measurements the load produced.
final class LoadedReply extends InferenceReply {
  const LoadedReply(this.runtime);

  static const String kind = 'loaded';

  final Map<String, Object?> runtime;

  @override
  Map<String, Object?> toWire() => {kindKey: kind, 'runtime': runtime};

  static LoadedReply fromWire(Map<String, Object?> wire) {
    final runtime = wire['runtime'];
    if (runtime is! Map) {
      throw const FormatException('loaded reply: missing runtime');
    }
    return LoadedReply(runtime.cast<String, Object?>());
  }
}

/// One item of a generation turn.
final class EventReply extends InferenceReply {
  const EventReply(this.event);

  static const String kind = 'event';

  final LlmEvent event;

  @override
  Map<String, Object?> toWire() => {kindKey: kind, 'event': encodeEvent(event)};

  static EventReply fromWire(Map<String, Object?> wire) {
    final event = wire['event'];
    if (event is! Map) {
      throw const FormatException('event reply: missing event');
    }
    return EventReply(decodeEvent(event.cast<String, Object?>()));
  }
}

/// The worker could not do what was asked.
///
/// Errors cross the boundary as a *message*, never as a thrown object: the
/// exception types the runtime throws come from native code and the plugin, and
/// re-throwing a copy of one in the app isolate would make callers catch types they
/// cannot see. [stateful] distinguishes "this turn failed" from "the engine is
/// gone", which is the difference between retrying and reloading.
final class FailureReply extends InferenceReply {
  const FailureReply({required this.message, this.stateful = false});

  static const String kind = 'failure';

  final String message;

  /// True when the failure invalidated the engine itself, so the caller must
  /// reload rather than retry the turn.
  final bool stateful;

  @override
  Map<String, Object?> toWire() => {
    kindKey: kind,
    'message': message,
    'stateful': stateful,
  };

  static FailureReply fromWire(Map<String, Object?> wire) => FailureReply(
    message: wire['message'] as String? ?? 'unspecified inference failure',
    stateful: wire['stateful'] == true,
  );
}

/// The worker has closed the model and is about to exit.
final class ShutdownReply extends InferenceReply {
  const ShutdownReply();

  static const String kind = 'shutdown';

  @override
  Map<String, Object?> toWire() => {kindKey: kind};
}

/// An [InferenceConfig] in encoded form. Aliased for readability at the call sites
/// that only pass it through.
typedef InferenceConfigWire = Map<String, Object?>;

/// Encodes a stream event.
///
/// Tool-call arguments are re-wrapped into a fresh `Map<String, Object?>` rather
/// than passed by reference: the map the plugin produced is `Map<String, dynamic>`
/// decoded from the model's JSON, and copying it here means the type that arrives
/// on the far side is the one the interface declares.
Map<String, Object?> encodeEvent(LlmEvent event) => switch (event) {
  LlmToken(:final text) => {kindKey: 'token', 'text': text},
  LlmToolCall(:final name, :final arguments) => {
    kindKey: 'tool',
    'name': name,
    'arguments': {...arguments},
  },
  LlmDone() => {kindKey: 'done'},
};

/// Decodes a stream event, throwing [FormatException] on an unknown variant.
LlmEvent decodeEvent(Map<String, Object?> wire) {
  final kind = wire[kindKey];
  switch (kind) {
    case 'token':
      final text = wire['text'];
      if (text is! String) {
        throw const FormatException('token event: missing text');
      }
      return LlmToken(text);
    case 'tool':
      final name = wire['name'];
      final arguments = wire['arguments'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('tool event: missing name');
      }
      if (arguments is! Map) {
        throw const FormatException('tool event: arguments must be a map');
      }
      return LlmToolCall(
        name: name,
        arguments: arguments.cast<String, Object?>(),
      );
    case 'done':
      return const LlmDone();
    default:
      throw FormatException('unknown llm event "$kind"');
  }
}

/// Encodes a tool declaration for the worker.
Map<String, Object?> encodeToolDefinition(ToolDefinition definition) => {
  'name': definition.name,
  'description': definition.description,
  'parameters': definition.parameters,
};

/// Decodes a tool declaration.
ToolDefinition decodeToolDefinition(Map<String, Object?> wire) {
  final name = wire['name'];
  final description = wire['description'];
  final parameters = wire['parameters'];
  if (name is! String || name.isEmpty) {
    throw const FormatException('tool definition: missing name');
  }
  if (description is! String) {
    throw const FormatException('tool definition: missing description');
  }
  if (parameters != null && parameters is! Map) {
    throw const FormatException('tool definition: parameters must be a map');
  }
  return ToolDefinition(
    name: name,
    description: description,
    parameters: parameters == null
        ? const {}
        : (parameters as Map).cast<String, Object?>(),
  );
}
