/// Identity, provenance and integrity fingerprint of an on-device model
/// artifact.
///
/// Gemma weights cannot live in the repository: they are 0.6–2.6GB, well past what
/// belongs in git or an app-store binary, and their use is governed by Google's
/// Gemma terms. So the app ships a *description* of the artifact it expects — file
/// name, source URL and a pinned SHA-256 — and provisions the bytes at runtime.
///
/// **Download gating is a per-repository fact, not a property of Gemma.** The task
/// this came from assumed every source needs an access token; measured against the
/// live hosts, the LiteRT-LM rebuilds differ from the base models. As of
/// 2026-07-30: `litert-community/gemma-4-E2B-it-litert-lm` reports
/// `gated: false` and its `resolve` URL answers an anonymous request with a 302 to
/// the CDN, while `litert-community/Gemma3-1B-IT` reports `gated: auto` and does
/// need a token. Accepting the licence still applies to *using* the model either
/// way; a token is only about *downloading*. Hence [ModelDescriptor.downloadUri]
/// and the token are independent build inputs, and neither is assumed.
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
  ///
  /// An opaque key, not a description: `…-int4` in an id is historical and asserts
  /// nothing about the artifact a given URL actually serves.
  final String id;

  /// Human-readable name for the "model ready" UI and log lines.
  final String displayName;

  /// File name the artifact is installed under **locally**. It need not match the
  /// remote file name — nothing fetches this — but the extension matters to the
  /// runtime: LiteRT-LM loads `.litertlm`, MediaPipe loads `.task`/`.bin`.
  ///
  /// Like [id], a `…-int4` in the value is historical and asserts nothing about what
  /// the configured URL serves. It is worth saying here rather than only on [id],
  /// because this string is the more visible of the two: it is the literal file on
  /// the device, the target of the README's side-load instructions, and what shows
  /// up in a device container browser. The value is kept anyway — renaming it would
  /// point `ModelStorage.installedFile` at a path that does not exist, turning every
  /// current install into `absent` and costing a full re-download.
  final String fileName;

  /// Where the model's licence is accepted.
  ///
  /// Distinct from whether a *download* needs a token: the licence governs use of
  /// the model and applies however the bytes were obtained.
  ///
  /// Shown to the operator as an instruction when provisioning is unconfigured, so
  /// it must be a URL that actually resolves — a 404 in the one place the app says
  /// what to do next is worse than saying nothing. It points at the Gemma terms
  /// rather than at a repository, because the repository and file are a deployment
  /// input (`FIELDOPS_MODEL_URI`) while the licence is the same wherever the bytes
  /// come from.
  ///
  /// A correction to an earlier version of this comment, since it was wrong in a way
  /// worth not repeating: it claimed a repository URL "could not be checked even in
  /// principle" because hosts answer `401` for gated *and* non-existent repositories
  /// alike. That is true of the **web** URL only. HuggingFace's API does distinguish
  /// them — `GET /api/models/<repo>` returns the repo with a `gated` field, or 404 —
  /// which is how the catalog's sizes and gating status below were established.
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
///   --dart-define=FIELDOPS_MODEL_URI=https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm \
///   --dart-define=FIELDOPS_MODEL_SHA256=<64 hex chars>
/// ```
///
/// A source that gates downloads also needs `FIELDOPS_MODEL_TOKEN`; the URL above
/// does not (see the library doc). The hash is not written here on purpose — see
/// [ModelDescriptor.sha256Hex] — but it can be read from the host without
/// downloading the artifact: HuggingFace's `paths-info` API returns the LFS object
/// id, which is the content SHA-256.
///
/// The URI and hash apply to the **active** model only. Provisioning two models
/// in one build is not a scenario the demo has: the device holds one set of
/// weights, chosen by how much RAM it has.
abstract final class ModelCatalog {
  /// Primary target: Gemma 4 E2B in a LiteRT-LM container. The quantisation is
  /// whatever the configured URL serves — the shipped `litert-community` build does
  /// not state one in its file name, so this does not claim INT4.
  static const gemma4E2bId = 'gemma-4-e2b-it-int4';

  /// Low-RAM alternative for mid-range devices — same [ModelDescriptor] shape,
  /// so nothing above the provisioner changes when the choice does.
  static const gemma31bId = 'gemma-3-1b-it-int4';

  /// The Gemma terms, which is what a reviewer actually has to accept. Verified to
  /// resolve; a specific model-repository URL is not written down here because it
  /// cannot be (see [ModelDescriptor.licensePage]).
  static const gemmaTermsUrl = 'https://ai.google.dev/gemma/terms';

  static const _catalog = <String, ModelDescriptor>{
    gemma4E2bId: ModelDescriptor(
      id: gemma4E2bId,
      displayName: 'Gemma 4 E2B (LiteRT-LM)',
      fileName: 'gemma-4-e2b-it-int4.litertlm',
      licensePage: gemmaTermsUrl,
      // litert-community/gemma-4-E2B-it-litert-lm → gemma-4-E2B-it.litertlm,
      // measured 2026-07-30. Progress display only; never an integrity check.
      approximateSizeBytes: 2588147712,
    ),
    gemma31bId: ModelDescriptor(
      id: gemma31bId,
      displayName: 'Gemma 3 1B (INT4, LiteRT-LM)',
      fileName: 'gemma-3-1b-it-int4.litertlm',
      licensePage: gemmaTermsUrl,
      // litert-community/Gemma3-1B-IT → gemma3-1b-it-int4.litertlm, measured
      // 2026-07-30. That repo is `gated: auto`, so this one does need a token.
      approximateSizeBytes: 584417280,
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
