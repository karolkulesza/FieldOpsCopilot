/// Dependency-injection seam for the agent half of the slice.
///
/// Task 1.5 built `ToolRegistry` and `GetPartsInventoryTool` and left them
/// without a production call site for the same reason Tasks 1.3, 1.4, 1.6 and 1.9
/// did — the tool reads the local inventory, and the database needed a key. Task
/// 1.11's `seededDatabaseProvider` supplies one.
///
/// **`AgentLoop` deliberately has no provider.** It is constructed per run by
/// `FieldJobViewModel`, from the registry here and the engine the warm-up
/// controller has finished loading. Two reasons, and the second is the load-bearing
/// one. It is cheap — the constructor builds a `ToolCallGuard` from
/// `registry.toolNames` and nothing else. And a loop instance is bound to an
/// engine instance, so a cached loop would outlive an engine that was disposed
/// and replaced (a re-provisioned model, a `deviceLlmEngineProvider` rebuild) and
/// would then call `generate` on a disposed engine — a `StateError` from a stale
/// cache, which is the failure a provider is supposed to prevent rather than
/// cause.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/providers.dart';
import '../retry_policy.dart';
import 'tool_registry.dart';
import 'tools/get_parts_inventory_tool.dart';

/// The tools the agent may call, over the seeded database.
///
/// One tool today. The spec's §2.2 lists three more
/// (`schedule_followup_appointment`, `raise_safety_hazard_alert`, and a
/// name-based parts search); each is a line in this list and nothing else, which
/// is the property Task 1.5's registry was built for.
///
/// Constructing a `ToolRegistry` validates every declaration and throws
/// `ToolSchemaException` on a malformed one. That throw is deliberately not caught
/// here: it means the app's own wiring is misdeclared, which no retry and no user
/// action can fix. It surfaces as a startup failure with the message attached —
/// [noRetry] so it surfaces at once rather than after ten backoffs.
final toolRegistryProvider = FutureProvider<ToolRegistry>(retry: noRetry, (
  ref,
) async {
  final database = await ref.watch(seededDatabaseProvider.future);
  return ToolRegistry([GetPartsInventoryTool(database)]);
});
