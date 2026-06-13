import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_downloader.dart';
import 'package:field_ops_copilot/services/models/model_provisioner.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for the HTTP half of Task 1.7.
///
/// These run against a real [HttpServer] on the loopback interface rather than a
/// mocked client, because the behaviour worth testing *is* HTTP behaviour:
/// redirect hops, `Content-Length` handling, and which requests carry the access
/// token. A mocked client would only replay the assumptions being tested.
void main() {
  late _FakeModelHost origin;
  late _FakeModelHost cdn;

  final body = utf8.encode('litertlm weights stand-in ' * 50);

  setUp(() async {
    origin = await _FakeModelHost.start(body: body);
    cdn = await _FakeModelHost.start(body: body);
  });

  tearDown(() async {
    await origin.stop();
    await cdn.stop();
  });

  group('body and length', () {
    test('streams the body and reports the declared length', () async {
      final downloader = HttpModelDownloader();
      addTearDown(downloader.close);

      final stream = await downloader.open(origin.uri('/model'));
      final received = await _collect(stream.bytes);

      expect(received, body);
      expect(stream.contentLength, body.length);
    });

    test('reports an unknown length for a chunked response', () async {
      origin.chunked = true;
      final downloader = HttpModelDownloader();
      addTearDown(downloader.close);

      final stream = await downloader.open(origin.uri('/model'));

      expect(
        stream.contentLength,
        isNull,
        reason: 'no Content-Length means the total is genuinely unknown',
      );
      expect(await _collect(stream.bytes), body);
    });
  });

  group('credentials across redirects', () {
    test('sends the token as a bearer credential', () async {
      final downloader = HttpModelDownloader();
      addTearDown(downloader.close);

      await _collect(
        (await downloader.open(
          origin.uri('/model'),
          authToken: 'tok-123',
        )).bytes,
      );

      expect(origin.requests.single.authorization, 'Bearer tok-123');
    });

    test('sends no Authorization header when there is no token', () async {
      final downloader = HttpModelDownloader();
      addTearDown(downloader.close);

      await _collect((await downloader.open(origin.uri('/model'))).bytes);

      expect(origin.requests.single.authorization, isNull);
    });

    test('keeps the token across a same-origin redirect', () async {
      origin.redirects['/gated'] = '/model';
      final downloader = HttpModelDownloader();
      addTearDown(downloader.close);

      final stream = await downloader.open(
        origin.uri('/gated'),
        authToken: 'tok-123',
      );
      expect(await _collect(stream.bytes), body);

      // Both hops stayed on the host the credential was issued for.
      expect(origin.requests.map((r) => r.path), ['/gated', '/model']);
      expect(
        origin.requests.every((r) => r.authorization == 'Bearer tok-123'),
        isTrue,
      );
    });

    test('drops the token on a cross-origin redirect', () async {
      // What a license-gated host actually does: authenticate at the origin,
      // then redirect to a pre-signed URL on a separate download host.
      origin.redirects['/gated'] = cdn.uri('/model').toString();
      final downloader = HttpModelDownloader();
      addTearDown(downloader.close);

      final stream = await downloader.open(
        origin.uri('/gated'),
        authToken: 'tok-123',
      );
      expect(await _collect(stream.bytes), body);

      expect(origin.requests.single.authorization, 'Bearer tok-123');
      expect(
        cdn.requests.single.authorization,
        isNull,
        reason: 'the bearer token must never reach the redirect target',
      );
    });
  });

  group('failures an operator has to act on', () {
    test('401 names the missing or invalid credential', () async {
      origin.statusFor['/model'] = HttpStatus.unauthorized;
      final downloader = HttpModelDownloader();
      addTearDown(downloader.close);

      await expectLater(
        downloader.open(origin.uri('/model')),
        throwsA(
          isA<ModelDownloadException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', contains('token')),
        ),
      );
    });

    test('403 points at the unaccepted license', () async {
      origin.statusFor['/model'] = HttpStatus.forbidden;
      final downloader = HttpModelDownloader();
      addTearDown(downloader.close);

      await expectLater(
        downloader.open(origin.uri('/model')),
        throwsA(
          isA<ModelDownloadException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.message, 'message', contains('license')),
        ),
      );
    });

    test('404 points at the file name and revision', () async {
      final downloader = HttpModelDownloader();
      addTearDown(downloader.close);

      await expectLater(
        downloader.open(origin.uri('/no-such-model')),
        throwsA(
          isA<ModelDownloadException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', contains('revision')),
        ),
      );
    });

    test('a redirect loop gives up instead of spinning', () async {
      origin.redirects['/loop'] = '/loop';
      final downloader = HttpModelDownloader(maxRedirects: 3);
      addTearDown(downloader.close);

      await expectLater(
        downloader.open(origin.uri('/loop')),
        throwsA(isA<ModelDownloadException>()),
      );
      // Bounded: the initial request plus at most maxRedirects hops.
      expect(origin.requests.length, 4);
    });

    test(
      'a redirect with no Location is reported, not followed blindly',
      () async {
        origin.locationlessRedirects.add('/headerless');
        final downloader = HttpModelDownloader();
        addTearDown(downloader.close);

        await expectLater(
          downloader.open(origin.uri('/headerless')),
          throwsA(
            isA<ModelDownloadException>().having(
              (e) => e.message,
              'message',
              contains('Location'),
            ),
          ),
        );
      },
    );
  });

  group('end to end over HTTP', () {
    test('provisions and verifies a real HTTP body', () async {
      final tempDir = await Directory.systemTemp.createTemp('fieldops_http');
      addTearDown(() => tempDir.delete(recursive: true));

      final storage = ModelStorage(root: Directory('${tempDir.path}/models'));
      final downloader = HttpModelDownloader();
      addTearDown(downloader.close);
      final provisioner = ModelProvisioner(
        storage: storage,
        downloader: downloader,
        authToken: 'tok-123',
      );

      // The redirect chain a real gated download takes, end to end.
      origin.redirects['/gated'] = cdn.uri('/model').toString();
      final descriptor = ModelDescriptor(
        id: 'gemma-http-test',
        displayName: 'Gemma (HTTP fixture)',
        fileName: 'gemma-http-test.litertlm',
        licensePage: 'https://example.invalid/license',
        downloadUri: origin.uri('/gated'),
        sha256Hex: sha256.convert(body).toString(),
      );

      final result = await provisioner.provision(descriptor);

      expect(result, isA<ModelVerified>());
      expect((result as ModelVerified).sizeBytes, body.length);
      expect(await storage.installedFile(descriptor).readAsBytes(), body);
      expect(await storage.statusOf(descriptor), ModelInstallStatus.ready);
    });
  });
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
  }
  return out;
}

/// One observed request: enough to assert what the client actually sent.
class _SeenRequest {
  _SeenRequest({required this.path, required this.authorization});

  final String path;
  final String? authorization;
}

/// A loopback stand-in for a license-gated model host.
class _FakeModelHost {
  _FakeModelHost._(this._server, this._body);

  static Future<_FakeModelHost> start({required List<int> body}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeModelHost._(server, body);
    host._serve();
    return host;
  }

  final HttpServer _server;
  final List<int> _body;

  /// Path -> `Location` value to redirect to.
  final Map<String, String> redirects = {};

  /// Paths that answer with a redirect status but no `Location` header.
  final Set<String> locationlessRedirects = {};

  /// Path -> status code to answer with instead of `200`.
  final Map<String, int> statusFor = {};

  /// Whether `/model` answers without a `Content-Length` (chunked).
  bool chunked = false;

  final List<_SeenRequest> requests = [];

  Uri uri(String path) =>
      Uri.parse('http://${_server.address.address}:${_server.port}$path');

  void _serve() {
    _server.listen((request) async {
      final path = request.uri.path;
      requests.add(
        _SeenRequest(
          path: path,
          authorization: request.headers.value(HttpHeaders.authorizationHeader),
        ),
      );
      final response = request.response;

      if (locationlessRedirects.contains(path)) {
        response.statusCode = HttpStatus.found;
        await response.close();
        return;
      }

      final redirect = redirects[path];
      if (redirect != null) {
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, redirect);
        await response.close();
        return;
      }

      final override = statusFor[path];
      if (override != null) {
        response.statusCode = override;
        await response.close();
        return;
      }

      if (path != '/model') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      if (!chunked) response.contentLength = _body.length;
      // Two writes, so a chunked response really is chunked.
      response.add(_body.sublist(0, _body.length ~/ 2));
      response.add(_body.sublist(_body.length ~/ 2));
      await response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}
