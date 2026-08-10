/// Identity, provenance and integrity fingerprint of an on-device model
/// artifact — which, since Task 2.0, may be a *set of files* rather than one.
///
/// Gemma weights cannot live in the repository: they are 0.6–2.6GB, well past what
/// belongs in git or an app-store binary, and their use is governed by Google's
/// Gemma terms. So the app ships a *description* of the artifact it expects — file
/// names, source URLs and pinned SHA-256 digests — and provisions the bytes at
/// runtime.
///
/// **Download gating is a per-repository fact, not a property of a model.** The
/// task this came from assumed every source needs an access token; measured
/// against the live hosts, the LiteRT-LM rebuilds differ from the base models. As
/// of 2026-07-30: `litert-community/gemma-4-E2B-it-litert-lm` reports
/// `gated: false` and its `resolve` URL answers an anonymous request with a 302 to
/// the CDN, while `litert-community/Gemma3-1B-IT` reports `gated: auto` and does
/// need a token. Accepting the licence still applies to *using* the model either
/// way; a token is only about *downloading*. Hence [ModelArtifactFile.downloadUri]
/// and the token are independent build inputs, and neither is assumed.
///
/// **Whether a source and hash may be committed follows from gating, and the two
/// models in this catalog land on opposite sides of it.** The Gemma URL and hash
/// are deliberately **not** hard-coded: the artifact is licence-gated, a URL is
/// revision-specific and a hash is bytes-specific, so both are supplied at build
/// time via `--dart-define` (see [ModelCatalog]) and a descriptor missing either
/// one refuses to provision rather than installing unverified weights. The STT
/// model's repository is `apache-2.0` and ungated (`gated: false`, measured
/// 2026-08-10 via the HuggingFace API), so its URLs and per-file hashes are
/// committed below — with no token and no `--dart-define`. The fail-closed rule is
/// unchanged either way: a file missing a pin still provisions nothing.
library;

/// Why a descriptor cannot be provisioned as configured.
enum ModelConfigurationIssue {
  /// At least one file of the model has no download URL.
  missingSource,

  /// At least one file has no valid SHA-256 pinned, so its downloaded bytes
  /// could not be trusted.
  unpinnedHash,
}

/// One file of a provisionable model artifact, with its own source and pin.
///
/// Task 1.7's descriptor *was* its single file; Task 2.0 splits the file out so a
/// model can be a set (the streaming-zipformer STT model is four files served
/// individually, not an archive). Integrity stays per file: each one carries its
/// own SHA-256, because a set-level digest could not say *which* file is wrong,
/// and the files are fetched and verified one at a time.
class ModelArtifactFile {
  ModelArtifactFile({
    required this.fileName,
    this.downloadUri,
    this.sha256Hex = '',
    this.approximateSizeBytes,
  });

  /// File name the artifact is installed under **locally**, inside the model's
  /// install directory. It need not match the remote file name — nothing fetches
  /// this — but the extension matters to the runtime: LiteRT-LM loads
  /// `.litertlm`, MediaPipe loads `.task`/`.bin`, sherpa-onnx loads `.onnx` plus
  /// a `tokens.txt`.
  final String fileName;

  /// Resolved download URL, or `null` when none has been configured.
  final Uri? downloadUri;

  /// Pinned SHA-256 as lower-case hex, or `''` when unpinned.
  final String sha256Hex;

  /// Documented file size, used only to make progress meaningful before the
  /// server reports `Content-Length`. Never used as an integrity check — that is
  /// the hash's job.
  final int? approximateSizeBytes;

  /// True when [sha256Hex] is a syntactically valid SHA-256 digest.
  ///
  /// Shape is all that can be checked here; whether it is the *right* digest is
  /// settled by hashing the bytes.
  bool get hasPinnedHash => ModelDescriptor._sha256Shape.hasMatch(sha256Hex);

  @override
  String toString() => 'ModelArtifactFile($fileName)';
}

/// An immutable description of one provisionable model artifact — one or more
/// files installed and verified as a unit.
class ModelDescriptor {
  /// Describes a single-file artifact.
  ///
  /// This is Task 1.7's original shape, kept as the constructor because every
  /// LLM this app can provision is one file — and because the build-time
  /// `--dart-define` overlay ([withSource], [ModelCatalog.resolve]) supplies
  /// exactly one URI and one hash, which is only coherent against exactly one
  /// file.
  ModelDescriptor({
    required this.id,
    required this.displayName,
    required String fileName,
    required this.licensePage,
    Uri? downloadUri,
    String sha256Hex = '',
    int? approximateSizeBytes,
  }) : files = List.unmodifiable([
         ModelArtifactFile(
           fileName: fileName,
           downloadUri: downloadUri,
           sha256Hex: sha256Hex,
           approximateSizeBytes: approximateSizeBytes,
         ),
       ]);

  /// Describes a multi-file artifact — the whole of Task 2.0's new capability.
  ///
  /// The set is provisioned all-or-nothing: it is `ready` only when *every* file
  /// is present and vouched for, and an install that fails partway installs
  /// nothing.
  ModelDescriptor.fileSet({
    required this.id,
    required this.displayName,
    required this.licensePage,
    required List<ModelArtifactFile> files,
  }) : files = List.unmodifiable(files) {
    if (files.isEmpty) {
      throw ArgumentError.value(files, 'files', 'a model must have files');
    }
    final names = files.map((f) => f.fileName).toSet();
    if (names.length != files.length) {
      // Two entries with one name would silently overwrite each other in the
      // install directory — the second download's bytes under the first file's
      // pin. Refuse at construction, where the mistake is a one-line diff away.
      throw ArgumentError.value(
        files.map((f) => f.fileName).toList(),
        'files',
        'file names within a model must be unique',
      );
    }
  }

  /// Stable identifier used for catalog lookup, receipt bookkeeping and the name
  /// of the model's install directory.
  ///
  /// An opaque key, not a description: `…-int4` in an id is historical and asserts
  /// nothing about the artifact a given URL actually serves.
  final String id;

  /// Human-readable name for the "model ready" UI and log lines.
  final String displayName;

  /// Where the model's licence is accepted.
  ///
  /// Distinct from whether a *download* needs a token: the licence governs use of
  /// the model and applies however the bytes were obtained.
  ///
  /// Shown to the operator as an instruction when provisioning is unconfigured, so
  /// it must be a URL that actually resolves — a 404 in the one place the app says
  /// what to do next is worse than saying nothing. For Gemma it points at the
  /// terms rather than at a repository, because the repository and file are a
  /// deployment input (`FIELDOPS_MODEL_URI`) while the licence is the same
  /// wherever the bytes come from. For the STT model the repository *is* the
  /// stable fact — its config is committed — so its own page serves.
  ///
  /// A correction to an earlier version of this comment, since it was wrong in a
  /// way worth not repeating: it claimed a repository URL "could not be checked
  /// even in principle" because hosts answer `401` for gated *and* non-existent
  /// repositories alike. That is true of the **web** URL only. HuggingFace's API
  /// does distinguish them — `GET /api/models/<repo>` returns the repo with a
  /// `gated` field, or 404 — which is how the catalog's sizes, hashes and gating
  /// status below were established.
  final String licensePage;

  /// The files this model consists of, in download order. Never empty.
  final List<ModelArtifactFile> files;

  /// The single file of a single-file model.
  ///
  /// Exists for the call sites that are single-file *by design* — the
  /// `--dart-define` overlay and the LLM inference config — where quietly picking
  /// `files.first` of a set would hide a real error. Throws [StateError] on a
  /// multi-file descriptor.
  ModelArtifactFile get soleFile => files.single;

  /// Sum of the documented file sizes, or `null` when any file lacks one.
  /// Progress display only; never an integrity check.
  int? get approximateSizeBytes {
    var total = 0;
    for (final file in files) {
      final size = file.approximateSizeBytes;
      if (size == null) return null;
      total += size;
    }
    return total;
  }

  /// The reason this descriptor cannot be provisioned, or `null` if it can.
  ///
  /// Checked across the whole set — one unconfigured file makes the model
  /// unprovisionable, because a "ready" model with a missing file is not ready.
  /// A missing source is reported ahead of an unpinned hash so a reviewer who
  /// has configured neither is pointed at the first step, not the second.
  ModelConfigurationIssue? get configurationIssue {
    if (files.any((f) => f.downloadUri == null)) {
      return ModelConfigurationIssue.missingSource;
    }
    if (files.any((f) => !f.hasPinnedHash)) {
      return ModelConfigurationIssue.unpinnedHash;
    }
    return null;
  }

  /// One string that changes iff any pinned digest in the set changes.
  ///
  /// `ModelProvisioningController` holds this to decide whether a failed
  /// download has already been tried against the *same* pins — for a single-file
  /// model it is exactly the old "the sha256Hex" comparison, and for a set it
  /// moves when any member pin moves.
  String get pinFingerprint =>
      files.map((f) => '${f.fileName}:${f.sha256Hex}').join('\n');

  /// Returns a copy carrying the given source and pinned hash.
  ///
  /// Both arguments overwrite unconditionally — a `null` [downloadUri] means
  /// "no source configured", not "keep what you had". A `copyWith` that treated
  /// `null` as "unchanged" could not express *removing* a source, and the whole
  /// point of this type is that an unconfigured artifact stays unprovisionable.
  ///
  /// Only meaningful for a single-file descriptor, because the build-time triple
  /// it exists for (`FIELDOPS_MODEL_URI` / `_SHA256`) names one source and one
  /// digest. Throws [StateError] on a multi-file descriptor rather than guessing
  /// which file the caller meant.
  ModelDescriptor withSource({
    required Uri? downloadUri,
    required String sha256Hex,
  }) {
    final file = soleFile;
    return ModelDescriptor(
      id: id,
      displayName: displayName,
      fileName: file.fileName,
      licensePage: licensePage,
      downloadUri: downloadUri,
      sha256Hex: sha256Hex,
      approximateSizeBytes: file.approximateSizeBytes,
    );
  }

  @override
  String toString() =>
      'ModelDescriptor($id, ${files.map((f) => f.fileName).join(', ')})';

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
/// For the **LLM**, model choice is a deployment decision, not a code change:
/// which entry is active, where its bytes come from and what they must hash to
/// are all supplied at build time.
///
/// ```sh
/// flutter run \
///   --dart-define=FIELDOPS_MODEL_ID=gemma-4-e2b-it-int4 \
///   --dart-define=FIELDOPS_MODEL_URI=https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm \
///   --dart-define=FIELDOPS_MODEL_SHA256=<64 hex chars>
/// ```
///
/// A source that gates downloads also needs `FIELDOPS_MODEL_TOKEN`; the URL above
/// does not (see the library doc). The Gemma hash is not written here on purpose —
/// see the library doc — but it can be read from the host without downloading the
/// artifact: HuggingFace's `paths-info` API returns the LFS object id, which is
/// the content SHA-256.
///
/// The URI and hash apply to the **active LLM** only. The STT model needs no
/// defines at all: its repository is ungated `apache-2.0`, so its URLs and hashes
/// are committed on the descriptor itself. That asymmetry is deliberate and
/// load-bearing — see TC-PROV-CFG-01, which asserts the two configuration paths
/// are independent.
abstract final class ModelCatalog {
  /// Primary target: Gemma 4 E2B in a LiteRT-LM container. The quantisation is
  /// whatever the configured URL serves — the shipped `litert-community` build does
  /// not state one in its file name, so this does not claim INT4.
  static const gemma4E2bId = 'gemma-4-e2b-it-int4';

  /// Low-RAM alternative for mid-range devices — same [ModelDescriptor] shape,
  /// so nothing above the provisioner changes when the choice does.
  static const gemma31bId = 'gemma-3-1b-it-int4';

  /// Streaming STT for Task 2.2, provisioned ahead of it by Task 2.0: a
  /// sherpa-onnx streaming zipformer (en, 20M params, int8), four files served
  /// individually from an ungated `apache-2.0` repository.
  static const sttZipformerId = 'stt-zipformer-en-20m';

  /// The Gemma terms, which is what a reviewer actually has to accept. Verified to
  /// resolve; a specific model-repository URL is not written down here because it
  /// cannot be (see [ModelDescriptor.licensePage]).
  static const gemmaTermsUrl = 'https://ai.google.dev/gemma/terms';

  /// The STT model's repository — licence (`apache-2.0`) and files in one place.
  static const sttRepoUrl =
      'https://huggingface.co/csukuangfj/'
      'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17';

  static final _catalog = <String, ModelDescriptor>{
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
    sttZipformerId: ModelDescriptor.fileSet(
      id: sttZipformerId,
      displayName: 'Zipformer STT (en, 20M, int8)',
      licensePage: sttRepoUrl,
      // All four measured 2026-08-10: sizes and SHA-256 pins from the HuggingFace
      // `paths-info` API (the LFS object id *is* the content SHA-256), and
      // `tokens.txt` — a non-LFS file the API carries no digest for — downloaded
      // and hashed directly. The joiner's pin was additionally cross-checked by
      // downloading the served bytes and hashing them: they agree.
      files: [
        ModelArtifactFile(
          fileName: 'encoder-epoch-99-avg-1.int8.onnx',
          downloadUri: Uri.parse(
            '$sttRepoUrl/resolve/main/encoder-epoch-99-avg-1.int8.onnx',
          ),
          sha256Hex:
              '3810755ce7c3ab26b42a8bcf39d191308fa27fb0f53358823ba46141d03b7eb3',
          approximateSizeBytes: 42845182,
        ),
        ModelArtifactFile(
          fileName: 'decoder-epoch-99-avg-1.int8.onnx',
          downloadUri: Uri.parse(
            '$sttRepoUrl/resolve/main/decoder-epoch-99-avg-1.int8.onnx',
          ),
          sha256Hex:
              '21e2a2acd961b3ac72f55be2f10f1a285e1b0b0ba010d7c0b6eab141411b163c',
          approximateSizeBytes: 539499,
        ),
        ModelArtifactFile(
          fileName: 'joiner-epoch-99-avg-1.int8.onnx',
          downloadUri: Uri.parse(
            '$sttRepoUrl/resolve/main/joiner-epoch-99-avg-1.int8.onnx',
          ),
          sha256Hex:
              'e085d73b593cf9b0707f370dbd656d58327d3fe36d80d849202ef81df02cb01e',
          approximateSizeBytes: 259572,
        ),
        ModelArtifactFile(
          fileName: 'tokens.txt',
          downloadUri: Uri.parse('$sttRepoUrl/resolve/main/tokens.txt'),
          sha256Hex:
              '49e3c2646595fd907228b3c6787069658f67b17377c60aeb8619c4551b2316fb',
          approximateSizeBytes: 5048,
        ),
      ],
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

  /// The LLM this build provisions, with any build-time source and hash
  /// overlaid.
  ///
  /// An unknown `FIELDOPS_MODEL_ID` falls back to the primary target rather than
  /// throwing at startup: a typo in a `--dart-define` should surface as a
  /// readable "not configured" state in the UI, not a crash before the first
  /// frame.
  static ModelDescriptor get active =>
      resolve(_catalog[_configuredId] ?? _catalog[gemma4E2bId]!);

  /// Every model this build provisions and the readiness UI reports on: the
  /// active LLM plus the committed-config STT model.
  ///
  /// A *list*, not a map, and the LLM comes first: the banner renders these in
  /// order, and the model the demo cannot run without belongs on top.
  static List<ModelDescriptor> get provisioned =>
      List.unmodifiable([active, _catalog[sttZipformerId]!]);

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
