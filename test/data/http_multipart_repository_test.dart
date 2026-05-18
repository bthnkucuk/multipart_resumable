import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:multipart_resumable/src/config.dart';
import 'package:multipart_resumable/src/data/http_api.dart';
import 'package:test/test.dart';

void main() {
  group('HttpMultipartRepository', () {
    late HttpServer server;
    late String base;
    late ResumableClientConfig config;
    late HttpMultipartRepository repo;
    late File tempFile;

    setUp(() async {
      tempFile = File('${Directory.systemTemp.path}/mp_http_test_${DateTime.now().microsecondsSinceEpoch}.bin');
      await tempFile.writeAsBytes(List<int>.generate(32, (i) => i % 256));
    });

    tearDown(() async {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    });

    setUpAll(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      base = 'http://127.0.0.1:${server.port}';

      server.listen((request) async {
        final path = request.uri.path;
        final method = request.method;

        Future<void> sendJson(int code, Object? body) async {
          request.response.statusCode = code;
          request.response.headers.contentType = ContentType.json;
          if (body is String) {
            request.response.write(body);
          } else {
            request.response.write(jsonEncode(body));
          }
          await request.response.close();
        }

        if (method == 'POST' && path.endsWith('/resumable-upload/init')) {
          await sendJson(200, {
            'id': 'u1',
            'contentType': 'application/octet-stream',
            'key': 'k1',
            'partSize': 16,
          });
          return;
        }

        if (method == 'POST' && path.endsWith('/upload')) {
          await sendJson(200, {'url': '$base/put-obj', 'key': 'sk', 'headers': <String, dynamic>{}});
          return;
        }

        if (method == 'GET' && path.endsWith('/resumable-upload/status')) {
          await sendJson(200, {
            'uploadedParts': [
              {'partNumber': 1, 'etag': 'e1'},
            ],
          });
          return;
        }

        if (method == 'POST' && path.endsWith('/resumable-upload/presign')) {
          await sendJson(200, {'url': '$base/part-upload'});
          return;
        }

        if (method == 'POST' && path.endsWith('/resumable-upload/complete')) {
          await sendJson(200, {});
          return;
        }

        if (method == 'PUT' && path.endsWith('/put-obj')) {
          await request.drain<void>();
          request.response
            ..statusCode = 200
            ..headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
          await request.response.close();
          return;
        }

        if (method == 'PUT' && path.endsWith('/part-upload')) {
          await request.drain<void>();
          request.response
            ..statusCode = 200
            ..headers.set('etag', '"part-etag-1"');
          await request.response.close();
          return;
        }

        if (method == 'PUT' && path.endsWith('/part-no-etag')) {
          await request.drain<void>();
          request.response.statusCode = 200;
          await request.response.close();
          return;
        }

        request.response.statusCode = 404;
        await request.response.close();
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    setUp(() {
      config = ResumableClientConfig(baseUrl: base, cdnBaseUrl: 'http://cdn.example');
      repo = HttpMultipartRepository(
        config: config,
        dio: Dio(BaseOptions(baseUrl: base)),
      );
    });

    test('init returns map from server', () async {
      final m = await repo.init(path: 'a.bin', fileSize: 100);
      expect(m['id'], 'u1');
      expect(m['partSize'], 16);
    });

    test('singleInit returns url and key', () async {
      final m = await repo.singleInit(path: 'a.bin', fileSize: 100);
      expect(m['url'], '$base/put-obj');
      expect(m['key'], 'sk');
    });

    test('uploadedParts maps part numbers', () async {
      final m = await repo.uploadedParts(id: 'u1');
      expect(m[1], 'e1');
    });

    test('uploadedParts coerces non-typed Map entries from JSON-like maps', () async {
      final dio = Dio(BaseOptions(baseUrl: base));
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            if (response.requestOptions.uri.path.contains('status')) {
              final sm = SplayTreeMap<dynamic, dynamic>()
                ..['partNumber'] = 1
                ..['etag'] = 'e1';
              response.data = {
                'uploadedParts': <Object>[sm],
              };
            }
            handler.next(response);
          },
        ),
      );
      final r = HttpMultipartRepository(
        config: ResumableClientConfig(baseUrl: base, cdnBaseUrl: 'http://cdn.example'),
        dio: dio,
      );
      final m = await r.uploadedParts(id: 'u1');
      expect(m[1], 'e1');
    });

    test('presignPartUrl returns url string', () async {
      final url = await repo.presignPartUrl(id: 'u1', partNumber: 2);
      expect(url, '$base/part-upload');
    });

    test('complete posts without throwing', () async {
      await expectLater(
        repo.complete(
          id: 'u1',
          parts: [
            {'PartNumber': 1, 'ETag': 'e'},
          ],
        ),
        completes,
      );
    });

    test('putPart returns normalized etag', () async {
      final etag = await repo.putPart(
        url: '$base/part-upload',
        file: tempFile,
        start: 0,
        length: 10,
        contentType: 'application/octet-stream',
      );
      expect(etag, 'part-etag-1');
    });

    test('putPart throws when ETag header missing', () async {
      await expectLater(
        repo.putPart(
          url: '$base/part-no-etag',
          file: tempFile,
          start: 0,
          length: 10,
          contentType: 'application/octet-stream',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('putObject completes', () async {
      await expectLater(
        repo.putObject(
          url: '$base/put-obj',
          file: tempFile,
          headers: const {'X-Test': '1'},
        ),
        completes,
      );
    });
  });

  group('HttpMultipartRepository error paths', () {
    late HttpServer server;
    late String base;

    setUpAll(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      base = 'http://127.0.0.1:${server.port}';

      server.listen((request) async {
        final path = request.uri.path;
        final method = request.method;

        if (method == 'POST' && path.endsWith('/resumable-upload/init')) {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write('null');
          await request.response.close();
          return;
        }
        if (method == 'GET' && path.endsWith('/resumable-upload/status')) {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write('[]');
          await request.response.close();
          return;
        }
        if (method == 'POST' && path.endsWith('/resumable-upload/presign')) {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write('{"other":true}');
          await request.response.close();
          return;
        }
        if (method == 'POST' && path.endsWith('/upload')) {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write('42');
          await request.response.close();
          return;
        }
        request.response.statusCode = 404;
        await request.response.close();
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    test('init throws when response is not a map', () async {
      final config = ResumableClientConfig(
        baseUrl: base,
        cdnBaseUrl: 'http://cdn',
      );
      final dio = Dio(BaseOptions(baseUrl: base));
      final repo = HttpMultipartRepository(config: config, dio: dio);
      await expectLater(repo.init(path: 'x', fileSize: 1), throwsA(isA<StateError>()));
    });

    test('uploadedParts fails when JSON body is not a map', () async {
      final config = ResumableClientConfig(baseUrl: base, cdnBaseUrl: 'http://cdn');
      final dio = Dio(BaseOptions(baseUrl: base));
      final repo = HttpMultipartRepository(config: config, dio: dio);
      await expectLater(repo.uploadedParts(id: 'x'), throwsA(anything));
    });

    test('presignPartUrl throws when url missing or wrong type', () async {
      final config = ResumableClientConfig(baseUrl: base, cdnBaseUrl: 'http://cdn');
      final dio = Dio(BaseOptions(baseUrl: base));
      final repo = HttpMultipartRepository(config: config, dio: dio);
      await expectLater(repo.presignPartUrl(id: 'x', partNumber: 1), throwsA(anything));
    });

    test('singleInit throws when body is not a map', () async {
      final config = ResumableClientConfig(baseUrl: base, cdnBaseUrl: 'http://cdn');
      final dio = Dio(BaseOptions(baseUrl: base));
      final repo = HttpMultipartRepository(config: config, dio: dio);
      await expectLater(repo.singleInit(path: 'x', fileSize: 1), throwsA(isA<StateError>()));
    });
  });

  group('HttpMultipartRepository init/presign invalid body', () {
    late HttpServer server;
    late String base;

    setUpAll(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final path = request.uri.path;
        final method = request.method;
        if (method == 'POST' && path.endsWith('/resumable-upload/init')) {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write('7');
          await request.response.close();
          return;
        }
        if (method == 'POST' && path.endsWith('/resumable-upload/presign')) {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write('null');
          await request.response.close();
          return;
        }
        request.response.statusCode = 404;
        await request.response.close();
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    test('init throws when JSON is not an object', () async {
      final config = ResumableClientConfig(baseUrl: base, cdnBaseUrl: 'http://cdn');
      final repo = HttpMultipartRepository(
        config: config,
        dio: Dio(BaseOptions(baseUrl: base)),
      );
      await expectLater(repo.init(path: 'x', fileSize: 1), throwsA(isA<StateError>()));
    });

    test('presign throws when JSON is not an object map', () async {
      final config = ResumableClientConfig(baseUrl: base, cdnBaseUrl: 'http://cdn');
      final repo = HttpMultipartRepository(
        config: config,
        dio: Dio(BaseOptions(baseUrl: base)),
      );
      await expectLater(repo.presignPartUrl(id: 'x', partNumber: 1), throwsA(isA<StateError>()));
    });
  });

  group('HttpMultipartRepository HTTP error propagation', () {
    late HttpServer server;
    late String base;

    setUpAll(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        // Always 429 for any path under this server
        request.response
          ..statusCode = 429
          ..headers.contentType = ContentType.json
          ..write('{"error":"rate limited"}');
        await request.response.close();
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    test('init surfaces HTTP 429 as DioException with response.statusCode', () async {
      final config = ResumableClientConfig(baseUrl: base, cdnBaseUrl: 'http://cdn');
      final repo = HttpMultipartRepository(
        config: config,
        dio: Dio(BaseOptions(baseUrl: base)),
      );
      await expectLater(
        repo.init(path: 'x', fileSize: 1),
        throwsA(
          isA<DioException>().having((e) => e.response?.statusCode, 'statusCode', 429),
        ),
      );
    });

    test('singleInit surfaces HTTP 429 as DioException', () async {
      final config = ResumableClientConfig(baseUrl: base, cdnBaseUrl: 'http://cdn');
      final repo = HttpMultipartRepository(
        config: config,
        dio: Dio(BaseOptions(baseUrl: base)),
      );
      await expectLater(
        repo.singleInit(path: 'x', fileSize: 1),
        throwsA(
          isA<DioException>().having((e) => e.response?.statusCode, 'statusCode', 429),
        ),
      );
    });

    test('version header is attached to API requests', () async {
      var capturedHeader = '';
      final hdrServer = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() async => hdrServer.close(force: true));
      hdrServer.listen((request) async {
        capturedHeader = request.headers.value('Resumable-Upload-Version') ?? '';
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"id":"i","contentType":"x","key":"k","partSize":16}');
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${hdrServer.port}';
      final config = ResumableClientConfig(baseUrl: url, cdnBaseUrl: 'http://cdn');
      final repo = HttpMultipartRepository(config: config, dio: Dio(BaseOptions(baseUrl: url)));
      await repo.init(path: 'x', fileSize: 1);
      expect(capturedHeader, '1.0');
    });
  });

  group('HttpMultipartRepository authorization header provider', () {
    late HttpServer server;
    late String base;
    late String? capturedAuth;
    late String? capturedCustomAuth;

    setUp(() async {
      capturedAuth = null;
      capturedCustomAuth = null;
      server = await HttpServer.bind('127.0.0.1', 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        capturedAuth = request.headers.value('Authorization');
        capturedCustomAuth = request.headers.value('X-Auth');
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"id":"i","contentType":"x","key":"k","partSize":16}');
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('attaches Authorization header when provider returns a token', () async {
      final config = ResumableClientConfig(
        baseUrl: base,
        cdnBaseUrl: 'http://cdn',
        authorizationHeaderProvider: () async => 'Bearer abc123',
      );
      final repo = HttpMultipartRepository(config: config, dio: Dio(BaseOptions(baseUrl: base)));
      await repo.init(path: 'x', fileSize: 1);
      expect(capturedAuth, 'Bearer abc123');
    });

    test('omits Authorization when provider returns null', () async {
      final config = ResumableClientConfig(
        baseUrl: base,
        cdnBaseUrl: 'http://cdn',
        authorizationHeaderProvider: () async => null,
      );
      final repo = HttpMultipartRepository(config: config, dio: Dio(BaseOptions(baseUrl: base)));
      await repo.init(path: 'x', fileSize: 1);
      expect(capturedAuth, isNull);
    });

    test('omits Authorization when provider returns empty string', () async {
      final config = ResumableClientConfig(
        baseUrl: base,
        cdnBaseUrl: 'http://cdn',
        authorizationHeaderProvider: () async => '',
      );
      final repo = HttpMultipartRepository(config: config, dio: Dio(BaseOptions(baseUrl: base)));
      await repo.init(path: 'x', fileSize: 1);
      expect(capturedAuth, isNull);
    });

    test('respects custom authorizationHeaderName', () async {
      final config = ResumableClientConfig(
        baseUrl: base,
        cdnBaseUrl: 'http://cdn',
        authorizationHeaderProvider: () async => 'tok',
        authorizationHeaderName: 'X-Auth',
      );
      final repo = HttpMultipartRepository(config: config, dio: Dio(BaseOptions(baseUrl: base)));
      await repo.init(path: 'x', fileSize: 1);
      expect(capturedAuth, isNull);
      expect(capturedCustomAuth, 'tok');
    });
  });
}
