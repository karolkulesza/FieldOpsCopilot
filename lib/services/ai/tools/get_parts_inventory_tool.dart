/// The agent's offline warehouse lookup — the first tool in the registry, and the
/// one the spec's §5.2 walkthrough calls.
library;

import '../../../engines/llm_engine.dart';
import '../../../engines/tool_schema.dart';
import '../../database/database_service.dart';
import '../../database/tables.dart';
import '../base_tool.dart';

/// Looks up one spare part in the local inventory by exact SKU.
///
/// Thin by design: Task 1.3 built `DatabaseService.inventoryPartBySku` for this call
/// site and put the three properties it needs *inside the query* rather than here —
/// the SKU is canonicalised with [normalizeSku] on the way in (trim + upper-case,
/// because from here the argument arrives from the *model* in whatever casing the
/// weights emitted), `inventory_parts.sku` is `COLLATE NOCASE` as a backstop for rows
/// written past the normaliser, and the lookup goes through the primary-key index
/// rather than a scan.
///
/// **Scope note, because the spec is two-minded about this tool's signature.** §2.2
/// describes `get_local_parts_inventory(sku_or_name)`, but the only lookup that
/// exists is exact-SKU: a name search would need a different query (FTS over
/// `inventory_parts.name`, which is not indexed) and a different answer shape (several
/// rows, or a disambiguation question — the spec's own §2.3 clarification loop). This
/// tool declares `sku` only, which is what TC-TOOL-REG-01 and TC-TOOL-EXEC-01 specify.
/// Name search is a separate tool, not a widened parameter.
class GetPartsInventoryTool extends AgentTool {
  GetPartsInventoryTool(this._database);

  /// The name the model emits. A `static const` because three test groups and the
  /// agent loop all need to name it, and a typo in any of them would otherwise look
  /// like an unknown-tool failure.
  static const String toolName = 'get_local_parts_inventory';

  /// The single declared argument.
  static const String skuParameter = 'sku';

  final DatabaseService _database;

  @override
  final ToolDefinition definition = ToolDefinition(
    name: toolName,
    // The description is the only thing telling the model *when* to reach for this
    // tool, and the last sentence is doing grounding work rather than documentation:
    // the failure mode this whole app exists to prevent is a confident answer about
    // stock that came from the weights.
    description:
        'Check the local offline warehouse inventory for a spare part by its '
        'exact SKU. Returns the number of units in stock and the warehouse '
        'location. Always call this before telling the technician whether a '
        'part is available — never state stock levels from memory.',
    parameters: objectSchema(
      properties: {
        skuParameter: {
          'type': 'string',
          'description':
              'Exact stock-keeping unit of the part, for example '
              '"BRK-990-XP". Case and surrounding spaces do not matter.',
        },
      },
      required: [skuParameter],
    ),
  );

  /// Runs the lookup.
  ///
  /// Two payload shapes, and the difference between them is load-bearing:
  ///
  /// * **Found** — `{'sku': …, 'in_stock': n, 'aisle': …}`, exactly the three keys the
  ///   spec's §5.2 tool-result example carries and TC-TOOL-EXEC-01 asserts. `sku`
  ///   echoes the **stored** row, not the model's spelling, so the next turn quotes the
  ///   canonical form back to the technician.
  /// * **Not found** — `{'sku': …, 'found': false}`. A distinct shape rather than
  ///   `in_stock: 0`, because "we do not carry this part" and "we carry it and have
  ///   none" are different sentences to a technician and the model can only tell them
  ///   apart if the payload does. `BELT-330-DRV` is seeded at zero stock precisely so
  ///   a test can hold the two apart. The echoed `sku` is the canonicalised form —
  ///   what was actually looked up, not what the model typed.
  ///
  /// `found: true` is deliberately absent from the success payload: the shape is pinned
  /// by §5.2 and by the AC, and `in_stock`'s presence already discriminates.
  ///
  /// `aisle` is `null` when the row has no recorded location. Present-and-null rather
  /// than omitted, because an omitted key is indistinguishable from a tool that does not
  /// report locations, and a placeholder string like `'unknown'` would be text the
  /// database does not contain. All five seeded rows have a location, so the null case
  /// is covered by a synthetic row.
  @override
  Future<Map<String, Object?>> execute(Map<String, Object?> arguments) async {
    final sku = ToolArguments(arguments).requiredString(skuParameter);
    final row = await _database.inventoryPartBySku(sku);
    if (row == null) {
      return {'sku': normalizeSku(sku), 'found': false};
    }
    return {'sku': row.sku, 'in_stock': row.stock, 'aisle': row.location};
  }
}
