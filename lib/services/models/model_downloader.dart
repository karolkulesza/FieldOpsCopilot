import 'dart:io';

/// A remote artifact opened for streaming, plus whatever the server said about
/// its size.
class ModelByteStream {
  const ModelByteStream({required this.bytes, this.contentLength});

  /// The body, chunk by chunk. Never buffered whole: a 2.59GB artifact must not
  /// pass through memory on its way to disk.
  final Stream<List<int>> bytes;

  /// Body length in bytes, or `null` when the server did not declare one
  /// (chunked transfer encoding). A `null` here is why progress reporting has to
  /// tolerate an unknown total.
  final int? contentLength;
}

/// A source that could not be opened for download.
class ModelDownloadException implements Exception {
  const ModelDownloadException(this.message, {this.statusCode});

  final String message;

  /// HTTP status, when the failure was an HTTP response rather than a transport
  /// error.
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'ModelDownloadException: $message'
      : 'ModelDownloadException($statusCode): $message';
}

/// Opens a model artifact for streaming.
///
/// A seam, not an abstraction for its own sake: unit tests provision from a
/// scripted byte stream, so the whole verify/install path is covered without a
/// network or a 2.4GB fixture.
abstract interface class ModelDownloader {
  /// Opens [uri] for reading, sending [authToken] as a bearer credential.
  ///
  /// Throws [ModelDownloadException] when the source cannot be opened.
  Future<ModelByteStream> open(Uri uri, {String? authToken});

  /// Releases any transport resources.
  void close();
}

/// `dart:io` implementation over [HttpClient].
///
/// Redirects are followed **manually** (`followRedirects = false` plus an
/// explicit hop loop) so that credential scoping is this repository's behaviour
/// rather than an inherited one. It matters here because a model host that *does*
/// gate downloads authenticates the first request and then redirects to a
/// pre-signed URL on a separate download host, and forwarding the bearer token to
/// that host would leak a credential covering the operator's whole account.
/// HuggingFace redirects to `*.cdn.hf.co` for a public repository — verified — so
/// the cross-origin hop happens even where no credential is involved; the gated
/// case cannot be observed without a token, since the request is refused before any
/// redirect.
///
/// To be precise about what this is and is not: `HttpClient` on Dart 3 already
/// strips `Authorization` on a cross-origin redirect and keeps it on a
/// same-origin one — the same policy implemented below, verified on Dart 3.12.2.
/// So this loop is not a fix for a live SDK bug. It is here because the
/// guarantee is then asserted by this repo's own tests, holds identically if the
/// transport is ever swapped (`package:http`, a plugin's installer), and gives
/// the hop bound and the operator-facing error messages somewhere to live.
class HttpModelDownloader implements ModelDownloader {
  HttpModelDownloader({HttpClient? client, this.maxRedirects = 5})
    : _client = client ?? HttpClient() {
    // Transport compression is handled in three layers, because leaving
    // `autoUncompress` at its default silently breaks both integrity and the size
    // check: `Content-Length` then describes the *encoded* body while the stream
    // yields *decoded* bytes, so any content-encoding host — a TLS-terminating
    // enterprise proxy is squarely in this app's fleet story — turns every
    // download into "truncated transfer: received 13000 of 95 bytes", sending the
    // operator after a problem that does not exist.
    //
    // 1. every request asks for `identity` (see [open]);
    // 2. a response that content-encodes anyway is rejected by name — that is the
    //    functional guard, since the pinned SHA-256 describes the artifact as
    //    published and an encoded body simply cannot be checked against it;
    // 3. and inflation is off, so bytes are never quietly rewritten in flight.
    //
    // Layer 3 is deliberately unobservable through layer 2: `HttpClient` leaves
    // `Content-Encoding` on the headers even when it inflates (verified on Dart
    // 3.12.2), so the rejection fires either way. It is kept as the belt to that
    // braces, and pinned by a test that reads the flag directly.
    _client.autoUncompress = false;
  }

  final HttpClient _client;

  /// Redirect hops allowed before giving up, guarding against a redirect loop.
  final int maxRedirects;

  static const _redirectCodes = {
    HttpStatus.movedPermanently,
    HttpStatus.found,
    HttpStatus.seeOther,
    HttpStatus.temporaryRedirect,
    HttpStatus.permanentRedirect,
  };

  @override
  Future<ModelByteStream> open(Uri uri, {String? authToken}) async {
    var target = uri;
    var token = authToken;

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final request = await _client.getUrl(target);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close();

      if (_redirectCodes.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) {
          throw ModelDownloadException(
            'redirect from $target carried no Location header',
            statusCode: response.statusCode,
          );
        }
        final next = target.resolve(location);
        // Cross-origin hop: the credential was issued for the origin, not for
        // whatever it delegates to.
        if (!_sameOrigin(next, target)) token = null;
        target = next;
        continue;
      }

      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw ModelDownloadException(
          _explain(response.statusCode, target),
          statusCode: response.statusCode,
        );
      }

      // With `autoUncompress` off, a content-encoded body would be hashed and
      // installed in its encoded form — which is not what the pin describes. The
      // request asked for `identity`; a server that ignored that is a condition to
      // name, not to paper over.
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (encoding != null && encoding.trim().toLowerCase() != 'identity') {
        await response.drain<void>();
        throw ModelDownloadException(
          'the model host returned Content-Encoding: $encoding for $target — the '
          'pinned SHA-256 describes the artifact as published, so a '
          'transport-encoded body cannot be verified. Fetch a direct, '
          'unencoded URL (or an origin that honours Accept-Encoding: identity).',
        );
      }

      final declared = response.headers.contentLength;
      return ModelByteStream(
        bytes: response,
        contentLength: declared >= 0 ? declared : null,
      );
    }

    throw ModelDownloadException(
      'gave up after $maxRedirects redirects starting at $uri',
    );
  }

  @override
  void close() => _client.close(force: true);

  /// Whether two URLs share scheme, host **and** port.
  ///
  /// Scheme and port are part of the comparison deliberately: a redirect from
  /// `https` down to `http`, or to a different service on the same host, is a
  /// different trust boundary than the one the credential was issued for.
  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  /// Turns a status code into something an operator can act on.
  ///
  /// The failures that actually happen here are license and revision mistakes,
  /// not generic HTTP errors, so they are named as such.
  static String _explain(int statusCode, Uri uri) => switch (statusCode) {
    HttpStatus.unauthorized =>
      'the model host rejected the credential (401) for $uri — supply a valid '
          'access token via FIELDOPS_MODEL_TOKEN',
    HttpStatus.forbidden =>
      'access to $uri is forbidden (403) — accept the model license with the '
          'account that issued the token, then retry',
    HttpStatus.notFound =>
      '$uri was not found (404) — check the file name and revision in '
          'FIELDOPS_MODEL_URI',
    _ => 'the model host returned HTTP $statusCode for $uri',
  };
}
