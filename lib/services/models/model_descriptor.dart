/// Identity, provenance and integrity fingerprint of an on-device model
/// artifact.
///
/// Gemma weights cannot live in the repository: they are license-gated (the
/// download requires accepting Google's Gemma terms on HuggingFace or Kaggle and
/// authenticating with a personal token) and 0.5–2.4GB in size. So the app ships
/// a *description* of the artifact it expects — file name, source URL and a
/// pinned SHA-256 — and provisions the bytes at runtime.
///
/// The source URL and the hash are deliberately **not** hard-coded in this file.
/// A URL is revision-specific and a hash is bytes-specific: writing either one
/// down here would encode a guess about a file this repository has never seen.
/// Both are supplied at build time via `--dart-define` (see [ModelCatalog]), and
/// a descriptor that is missing either one refuses to provision rather than
/// installing unverified weights.
library;

/// Why a descriptor cannot be provisioned as configured.
enum ModelConfigurationIssue {
  /// No download URL was supplied for this model.
  missingSource,

  /// No valid SHA-256 was pinned, so downloaded bytes could not be trusted.
  unpinnedHash,
}

/// An immutable description of one provisionable model artifact.
class ModelDescriptor {
  const ModelDescriptor({
    required this.id,
    required this.displayName,
    required this.fileName,
    required this.licensePage,
    this.downloadUri,
    this.sha256Hex = '',
    this.approximateSizeBytes,
  });

  /// Stable identifier used for catalog lookup and receipt bookkeeping.
  final String id;

  /// Human-readable name for the "model ready" UI and log lines.
  final String displayName;

  /// File name the artifact is installed under. The extension matters to the
  /// runtime: LiteRT-LM loads `.litertlm`, MediaPipe loads `.task`/`.bin`.
  final String fileName;

  /// Where a reviewer accepts the license and obtains a download token.
  final String licensePage;

  /// Resolved download URL, or `null` when none has been configured.
  final Uri? downloadUri;

  /// Pinned SHA-256 as lower-case hex, or `''` when unpinned.
  final String sha256Hex;

  /// Documented artifact size, used only to make progress meaningful before the
  /// server reports `Content-Length`. Never used as an integrity check — that is
  /// the hash's job.
  final int? approximateSizeBytes;

  /// True when [sha256Hex] is a syntactically valid SHA-256 digest.
  ///
  /// Shape is all that can be checked here; whether it is the *right* digest is
  /// settled by hashing the bytes.
  bool get hasPinnedHash => _sha256Shape.hasMatch(sha256Hex);

  /// The reason this descriptor cannot be provisioned, or `null` if it can.
  ///
  /// A missing source is reported ahead of an unpinned hash so a reviewer who
  /// has configured neither is pointed at the first step, not the second.
  ModelConfigurationIssue? get configurationIssue {
    if (downloadUri == null) return ModelConfigurationIssue.missingSource;
    if (!hasPinnedHash) return ModelConfigurationIssue.unpinnedHash;
    return null;
  }

  /// Returns a copy carrying the given source and pinned hash.
  ///
  /// Both arguments overwrite unconditionally — a `null` [downloadUri] means
  /// "no source configured", not "keep what you had". A `copyWith` that treated
  /// `null` as "unchanged" could not express *removing* a source, and the whole
  /// point of this type is that an unconfigured artifact stays unprovisionable.
  ModelDescriptor withSource({
    required Uri? downloadUri,
    required String sha256Hex,
  }) => ModelDescriptor(
    id: id,
    displayName: displayName,
    fileName: fileName,
    licensePage: licensePage,
    downloadUri: downloadUri,
    sha256Hex: sha256Hex,
    approximateSizeBytes: approximateSizeBytes,
  );

  @override
  String toString() => 'ModelDescriptor($id, $fileName)';

  static final RegExp _sha256Shape = RegExp(r'^[0-9a-f]{64}$');

  /// Canonicalises a user-supplied digest: trimmed and lower-cased.
  ///
  /// `shasum`, `sha256sum` and the HuggingFace UI all render hex differently
  /// (case, surrounding whitespace, a trailing file name). Comparing raw strings
  /// would reject a correct hash pasted in the wrong case, which reads to the
  /// operator as a corrupt download — the one failure this layer must never fake.
  static String normalizeHash(String raw) {
    final trimmed = raw.trim().toLowerCase();
    // `shasum -a 256 file` prints "<hex>  <path>"; keep just the digest.
    final firstToken = trimmed.split(RegExp(r'\s+')).first;
    return firstToken;
  }
}

/// The models this app knows how to provision.
///
/// Model choice is a deployment decision, not a code change: which entry is
/// active, where its bytes come from and what they must hash to are all supplied
/// at build time.
///
/// ```sh
/// flutter run \
///   --dart-define=FIELDOPS_MODEL_ID=gemma-4-e2b-it-int4 \
///   --dart-define=FIELDOPS_MODEL_URI=https://…/gemma-4-e2b-it-int4.litertlm \
///   --dart-define=FIELDOPS_MODEL_SHA256=<64 hex chars>
/// ```
///
/// The URI and hash apply to the **active** model only. Provisioning two models
/// in one build is not a scenario the demo has: the device holds one set of
/// weights, chosen by how much RAM it has.
abstract final class ModelCatalog {
  /// Primary target: Gemma 4 E2B, INT4, LiteRT-LM container.
  static const gemma4E2bId = 'gemma-4-e2b-it-int4';

  /// Low-RAM alternative for mid-range devices — same [ModelDescriptor] shape,
  /// so nothing above the provisioner changes when the choice does.
  static const gemma31bId = 'gemma-3-1b-it-int4';

  static const _catalog = <String, ModelDescriptor>{
    gemma4E2bId: ModelDescriptor(
      id: gemma4E2bId,
      displayName: 'Gemma 4 E2B (INT4, LiteRT-LM)',
      fileName: 'gemma-4-e2b-it-int4.litertlm',
      licensePage: 'https://huggingface.co/google/gemma-4-e2b-it-litert-lm',
      approximateSizeBytes: 2400 * 1000 * 1000,
    ),
    gemma31bId: ModelDescriptor(
      id: gemma31bId,
      displayName: 'Gemma 3 1B (INT4, LiteRT-LM)',
      fileName: 'gemma-3-1b-it-int4.litertlm',
      licensePage: 'https://huggingface.co/google/gemma-3-1b-it-litert-lm',
      approximateSizeBytes: 550 * 1000 * 1000,
    ),
  };

  static const _configuredId = String.fromEnvironment(
    'FIELDOPS_MODEL_ID',
    defaultValue: gemma4E2bId,
  );
  static const _configuredUri = String.fromEnvironment('FIELDOPS_MODEL_URI');
  static const _configuredHash = String.fromEnvironment(
    'FIELDOPS_MODEL_SHA256',
  );

  /// Every known model, in catalog order.
  static List<ModelDescriptor> get all =>
      _catalog.values.toList(growable: false);

  /// Look up a model by [id], or `null` when it is not in the catalog.
  static ModelDescriptor? byId(String id) => _catalog[id];

  /// The model this build provisions, with any build-time source and hash
  /// overlaid.
  ///
  /// An unknown `FIELDOPS_MODEL_ID` falls back to the primary target rather than
  /// throwing at startup: a typo in a `--dart-define` should surface as a
  /// readable "not configured" state in the UI, not a crash before the first
  /// frame.
  static ModelDescriptor get active =>
      resolve(_catalog[_configuredId] ?? _catalog[gemma4E2bId]!);

  /// Overlays the build-time source URL and pinned hash onto [descriptor].
  ///
  /// Exposed so tests can exercise the overlay without a `--dart-define`.
  static ModelDescriptor resolve(
    ModelDescriptor descriptor, {
    String uri = _configuredUri,
    String sha256Hex = _configuredHash,
  }) => descriptor.withSource(
    downloadUri: uri.trim().isEmpty ? null : Uri.tryParse(uri.trim()),
    sha256Hex: ModelDescriptor.normalizeHash(sha256Hex),
  );
}
