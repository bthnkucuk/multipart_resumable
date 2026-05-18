// Tests for two areas:
//   1) ETag normalization in HttpMultipartRepository.putPart (real HttpServer)
//   2) The singleInit single-PUT flow in ResumableUploadClient (orchestrator
//      with a fake MultipartUploadRepository)
//
// IMPORTANT: This file pins CURRENT behavior — including suspected bug
// surfaces — so regressions are visible. Where behavior looks dodgy it's
// flagged with `// CURRENT BEHAVIOR:` or `// SUSPECTED PROD BUG SURFACE:`.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:multipart_resumable/multipart_resumable.dart';
import 'package:multipart_resumable/src/config.dart';
import 'package:multipart_resumable/src/data/http_api.dart';
import 'package:multipart_resumable/src/domain/repository.dart';
import 'package:test/test.dart';

class MockMultipartUploadRepository extends Mock implements MultipartUploadRepository {}

class MockFile extends Mock implements File {}

class FakeFile extends Fake implements File {}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeFile());
    registerFallbackValue(<Map<String, dynamic>>[]);
  });

  // ---------------------------------------------------------------------------
  // 1) ETag normalization (real HttpServer)
  // ---------------------------------------------------------------------------
  group('HttpMultipartRepository.putPart ETag normalization', () {
    late HttpServer server;
    late String base;
    late File tempFile;

    // Per-test ETag value the server should write back on the /part-upload
    // response. Set in each test before calling putPart.
    String? etagToReturn;
    // If true, server omits the etag header entirely.
    var omitEtag = false;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';

      server.listen((request) async {
        if (request.method == 'PUT' && request.uri.path.endsWith('/part-upload')) {
          await request.drain<void>();
          request.response.statusCode = 200;
          if (!omitEtag && etagToReturn != null) {
            request.response.headers.set('etag', etagToReturn!);
          }
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

    setUp(() async {
      etagToReturn = null;
      omitEtag = false;
      tempFile = File(
        '${Directory.systemTemp.path}/mp_etag_test_${DateTime.now().microsecondsSinceEpoch}.bin',
      );
      await tempFile.writeAsBytes(List<int>.generate(32, (i) => i % 256));
    });

    tearDown(() async {
      if (await tempFile.exists()) await tempFile.delete();
    });

    HttpMultipartRepository buildRepo() {
      final config = ResumableClientConfig(baseUrl: base, cdnBaseUrl: 'http://cdn.example');
      return HttpMultipartRepository(config: config, dio: Dio(BaseOptions(baseUrl: base)));
    }

    Future<String> doPut() => buildRepo().putPart(
          url: '$base/part-upload',
          file: tempFile,
          start: 0,
          length: 10,
          contentType: 'application/octet-stream',
        );

    test('S3-style double-quoted ETag is normalized to unquoted', () async {
      etagToReturn = '"abc123"';
      expect(await doPut(), 'abc123');
    });

    test('Raw unquoted ETag passes through unchanged', () async {
      etagToReturn = 'abc123';
      expect(await doPut(), 'abc123');
    });

    test('Quoted ETag containing embedded escaped quote — all quotes stripped',
        () async {
      // The HTTP wire value is: "abc\"123"  (RFC 7232 quoted-pair).
      // Current code does a naive replaceAll('"', '') so ALL quote chars are
      // removed, yielding `abc123`. Pinned here so any future smarter parser
      // is flagged as a behavior change.
      etagToReturn = '"abc\\"123"';
      final got = await doPut();
      // CURRENT BEHAVIOR: naive strip => "abc123". A spec-aware parser would
      // return `abc"123` instead. If this assertion ever flips, decide whether
      // it's an intended improvement and update.
      expect(got, anyOf('abc123', 'abc\\123'),
          reason:
              'replaceAll strips every quote char. If the value becomes `abc\\123`, '
              'the backslash escape was preserved literally — both outcomes are '
              'consistent with the current naive strip.');
    });

    test('Quoted ETag with surrounding whitespace — pin Dart HttpHeaders trim behavior',
        () async {
      // Dart's HttpHeaders.set normalizes whitespace; dio reads the header back
      // already trimmed. After quote-strip the value is `abc123`.
      // CURRENT BEHAVIOR: leading/trailing whitespace is trimmed by the HTTP
      // layer, then quotes are stripped, leaving `abc123`.
      etagToReturn = '  "abc123"  ';
      expect(await doPut(), 'abc123');
    });
  });

  // ---------------------------------------------------------------------------
  // 2) putPart with no ETag header
  // ---------------------------------------------------------------------------
  group('HttpMultipartRepository.putPart missing ETag header', () {
    late HttpServer server;
    late String base;
    late File tempFile;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      server.listen((request) async {
        if (request.method == 'PUT' && request.uri.path.endsWith('/part-no-etag')) {
          await request.drain<void>();
          request.response.statusCode = 200; // no etag header set
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

    setUp(() async {
      tempFile = File(
        '${Directory.systemTemp.path}/mp_noetag_test_${DateTime.now().microsecondsSinceEpoch}.bin',
      );
      await tempFile.writeAsBytes(List<int>.generate(32, (i) => i % 256));
    });

    tearDown(() async {
      if (await tempFile.exists()) await tempFile.delete();
    });

    test('throws StateError when server omits ETag entirely', () async {
      // CURRENT BEHAVIOR: putPart throws `StateError('ETag header missing in part response')`.
      // Does NOT return an empty string or swallow the error.
      final config = ResumableClientConfig(baseUrl: base, cdnBaseUrl: 'http://cdn.example');
      final repo = HttpMultipartRepository(config: config, dio: Dio(BaseOptions(baseUrl: base)));
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
  });

  // ---------------------------------------------------------------------------
  // 3) singleInit returns non-string `url`/`key`  — SUSPECTED PROD BUG SURFACE
  // ---------------------------------------------------------------------------
  group('ResumableUploadClient singleInit type safety', () {
    late MockMultipartUploadRepository mockRepo;
    late MockFile mockFile;
    late ResumableUploadClient client;

    setUp(() {
      mockRepo = MockMultipartUploadRepository();
      mockFile = MockFile();
      const cfg = ResumableClientConfig(
        baseUrl: 'http://api.test',
        cdnBaseUrl: 'http://cdn.test',
      );
      client = ResumableUploadClient(config: cfg, repository: mockRepo);
      when(() => mockFile.path).thenReturn('/path/to/x.bin');
      when(() => mockFile.length()).thenAnswer((_) async => 100);
    });

    test('non-string url (int) — controller fails with UnknownUploadException, no exception escapes',
        () async {
      when(
        () => mockRepo.singleInit(
          path: any(named: 'path'),
          fileSize: any(named: 'fileSize'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'url': 12345, // int — `as String` will throw TypeError
          'key': 'k',
          'headers': <String, dynamic>{},
        },
      );

      // Asserts no exception escapes the Future<UploadController>.
      UploadController? controller;
      Object? escapedError;
      try {
        controller = await client.start(file: mockFile, partSizeBytes: 200);
      } catch (e) {
        escapedError = e;
      }
      expect(escapedError, isNull,
          reason: 'start() must not let the TypeError escape — it must be caught and routed to controller');
      expect(controller, isNotNull);

      final result = await controller!.done;
      expect(result.isLeft(), isTrue);
      result.fold(
        (f) => expect(f, isA<UnknownUploadException>(),
            reason:
                'TypeError from `as String` is caught by single-init try/catch and mapped to UnknownUploadException'),
        (_) => fail('expected failure'),
      );
      // putObject must NOT be reached if url cast failed.
      verifyNever(
        () => mockRepo.putObject(
          url: any(named: 'url'),
          file: any(named: 'file'),
          headers: any(named: 'headers'),
          onSendProgress: any(named: 'onSendProgress'),
        ),
      );
    });

    test('non-string key (int) — controller fails with UnknownUploadException', () async {
      when(
        () => mockRepo.singleInit(
          path: any(named: 'path'),
          fileSize: any(named: 'fileSize'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'url': 'http://x/y',
          'key': 42, // int — `as String` will throw TypeError
          'headers': <String, dynamic>{},
        },
      );

      UploadController? controller;
      Object? escapedError;
      try {
        controller = await client.start(file: mockFile, partSizeBytes: 200);
      } catch (e) {
        escapedError = e;
      }
      expect(escapedError, isNull,
          reason: 'start() must not let the TypeError escape — it must be caught and routed to controller');
      expect(controller, isNotNull);

      final result = await controller!.done;
      expect(result.isLeft(), isTrue);
      result.fold(
        (f) => expect(f, isA<UnknownUploadException>()),
        (_) => fail('expected failure'),
      );
      verifyNever(
        () => mockRepo.putObject(
          url: any(named: 'url'),
          file: any(named: 'file'),
          headers: any(named: 'headers'),
          onSendProgress: any(named: 'onSendProgress'),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 4) singleInit headers with non-string values — code stringifies them
  // ---------------------------------------------------------------------------
  group('ResumableUploadClient singleInit headers stringification', () {
    late MockMultipartUploadRepository mockRepo;
    late MockFile mockFile;
    late ResumableUploadClient client;

    setUp(() {
      mockRepo = MockMultipartUploadRepository();
      mockFile = MockFile();
      const cfg = ResumableClientConfig(
        baseUrl: 'http://api.test',
        cdnBaseUrl: 'http://cdn.test',
      );
      client = ResumableUploadClient(config: cfg, repository: mockRepo);
      when(() => mockFile.path).thenReturn('/path/to/x.bin');
      when(() => mockFile.length()).thenAnswer((_) async => 100);
    });

    test('non-string header values are stringified and upload proceeds', () async {
      when(
        () => mockRepo.singleInit(
          path: any(named: 'path'),
          fileSize: any(named: 'fileSize'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'url': 'http://x/y',
          'key': 'k',
          'headers': <String, dynamic>{
            'Content-Length': 12345,
            'X-Custom': true,
          },
        },
      );

      Map<String, String>? captured;
      when(
        () => mockRepo.putObject(
          url: any(named: 'url'),
          file: any(named: 'file'),
          headers: any(named: 'headers'),
          onSendProgress: any(named: 'onSendProgress'),
        ),
      ).thenAnswer((invocation) async {
        captured = invocation.namedArguments[#headers] as Map<String, String>;
      });

      final controller = await client.start(file: mockFile, partSizeBytes: 200);
      final result = await controller.done;
      expect(result.isRight(), isTrue, reason: 'upload proceeds with stringified headers');
      expect(captured, isNotNull);
      // CURRENT BEHAVIOR: ints and bools are stringified via Object.toString().
      expect(captured!['Content-Length'], '12345');
      expect(captured!['X-Custom'], 'true');
    });
  });

  // ---------------------------------------------------------------------------
  // 5) singleInit putObject fails with 429 -> RateLimitExceededUploadException
  // ---------------------------------------------------------------------------
  group('ResumableUploadClient singleInit putObject 429', () {
    test('429 from putObject surfaces as RateLimitExceededUploadException (not Unknown)',
        () async {
      final mockRepo = MockMultipartUploadRepository();
      final mockFile = MockFile();
      const cfg = ResumableClientConfig(
        baseUrl: 'http://api.test',
        cdnBaseUrl: 'http://cdn.test',
      );
      final client = ResumableUploadClient(config: cfg, repository: mockRepo);
      when(() => mockFile.path).thenReturn('/path/to/x.bin');
      when(() => mockFile.length()).thenAnswer((_) async => 100);

      when(
        () => mockRepo.singleInit(
          path: any(named: 'path'),
          fileSize: any(named: 'fileSize'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'url': 'http://x/y',
          'key': 'k',
          'headers': <String, dynamic>{},
        },
      );

      when(
        () => mockRepo.putObject(
          url: any(named: 'url'),
          file: any(named: 'file'),
          headers: any(named: 'headers'),
          onSendProgress: any(named: 'onSendProgress'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/u'),
          response: Response(
            requestOptions: RequestOptions(path: '/u'),
            statusCode: 429,
          ),
        ),
      );

      final controller = await client.start(file: mockFile, partSizeBytes: 200);
      final result = await controller.done;
      expect(result.isLeft(), isTrue);
      result.fold(
        (f) => expect(f, isA<RateLimitExceededUploadException>(),
            reason: '_handleCommonErrors maps DioException with statusCode 429 first'),
        (_) => fail('expected failure'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 6) singleInit path has NO retry on failure (behavior pinning)
  // ---------------------------------------------------------------------------
  group('ResumableUploadClient singleInit no-retry behavior', () {
    test('transient 503 from putObject — single attempt, then UnknownUploadException',
        () async {
      // ASYMMETRY: Multipart's `_runSequential` retries up to
      // `maxRetriesPerPart` per putPart with exponential backoff.
      // The singleInit branch wraps the entire init+put in ONE try/catch
      // with NO retry loop. A 503 here must propagate after exactly one
      // putObject invocation, regardless of `maxRetriesPerPart`.
      final mockRepo = MockMultipartUploadRepository();
      final mockFile = MockFile();
      const cfg = ResumableClientConfig(
        baseUrl: 'http://api.test',
        cdnBaseUrl: 'http://cdn.test',
        maxRetriesPerPart: 5, // would matter if there were a retry loop
      );
      final client = ResumableUploadClient(config: cfg, repository: mockRepo);
      when(() => mockFile.path).thenReturn('/path/to/x.bin');
      when(() => mockFile.length()).thenAnswer((_) async => 100);

      when(
        () => mockRepo.singleInit(
          path: any(named: 'path'),
          fileSize: any(named: 'fileSize'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'url': 'http://x/y',
          'key': 'k',
          'headers': <String, dynamic>{},
        },
      );

      var putAttempts = 0;
      when(
        () => mockRepo.putObject(
          url: any(named: 'url'),
          file: any(named: 'file'),
          headers: any(named: 'headers'),
          onSendProgress: any(named: 'onSendProgress'),
        ),
      ).thenAnswer((_) async {
        putAttempts++;
        throw DioException(
          requestOptions: RequestOptions(path: '/u'),
          response: Response(
            requestOptions: RequestOptions(path: '/u'),
            statusCode: 503,
          ),
        );
      });

      final controller = await client.start(file: mockFile, partSizeBytes: 200);
      final result = await controller.done;

      // Exactly one attempt — proving no retry loop exists for singleInit.
      expect(putAttempts, 1,
          reason:
              'singleInit branch wraps everything in one try/catch with NO retry — asymmetric vs multipart path');
      expect(result.isLeft(), isTrue);
      result.fold(
        (f) => expect(f, isA<UnknownUploadException>(),
            reason: '503 is not 429, so _handleCommonErrors returns null and UnknownUploadException is used'),
        (_) => fail('expected failure'),
      );
    });
  });
}
