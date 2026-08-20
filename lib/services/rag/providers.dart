/// Dependency-injection seam for the retrieval half of the slice.
///
/// `RetrievalRouter` and `PromptCompiler` were both built without a production
/// call site, for one recurring reason: a
/// router needs a `DatabaseService` and a database needed a key.
/// `seededDatabaseProvider` supplies one, so these are the two lines that were
/// waiting.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/providers.dart';
import '../retry_policy.dart';
import 'prompt_compiler.dart';
import 'retrieval_router.dart';

/// The hybrid retrieval router, over the seeded database.
///
/// Depends on [seededDatabaseProvider] rather than [appDatabaseProvider], which
/// is the whole reason that provider exists: a router over an unseeded database
/// answers every query with nothing, and "nothing" is a legitimate retrieval
/// result the prompt compiler renders as its no-match block. So the failure would
/// not look like a failure — it would look like a manual that has no entry for
/// anything, phrased confidently.
///
/// [noRetry] for the reason `retry_policy.dart` gives: the only way constructing
/// this fails is that the database or the seed did, and neither improves on a
/// second attempt.
final retrievalRouterProvider = FutureProvider<RetrievalRouter>(
  retry: noRetry,
  (ref) async =>
      RetrievalRouter(await ref.watch(seededDatabaseProvider.future)),
);

/// The grounded-prompt compiler.
///
/// Synchronous and stateless — it holds a document budget and nothing else — so
/// this is a plain `Provider`. It exists as a provider anyway rather than as a
/// `const PromptCompiler()` at the call site, because
/// [PromptCompiler.maxDocuments] is a prompt budget against a 2048-token context
/// window, and the value that belongs in a demo build is a thing someone may want
/// to override without editing the viewmodel.
final promptCompilerProvider = Provider<PromptCompiler>(
  (ref) => const PromptCompiler(),
);
