/// Dependency-injection seam for the agent half of the slice.
///
/// `ToolRegistry` and `GetPartsInventoryTool` were built without a production
/// call site, like most of the agent stack — the tool reads the local inventory,
/// and the database needed a key. `seededDatabaseProvider` supplies one.
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
import 'tools/record_work_order_fields_tool.dart';

/// The tools the agent may call, over the seeded database.
///
/// Two tools. `record_work_order_fields` came second, and adding it was one
/// line here plus one file — which is the property the registry was built
/// for, now demonstrated rather than predicted. Three more are envisioned
/// (`schedule_followup_appointment`, `raise_safety_hazard_alert`, and a
/// name-based parts search) and each is the same one line.
///
/// **The order is the order the model is told about them**, and the lookup comes
/// first deliberately: `get_local_parts_inventory` is the tool whose result the
/// answer has to be grounded in, and `record_work_order_fields` is a side channel
/// that records what has already been established. A run that records first and
/// looks up second is not wrong, only less useful — it writes a SKU the model has
/// not checked.
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
  return ToolRegistry([
    GetPartsInventoryTool(database),
    RecordWorkOrderFieldsTool(),
  ]);
});
