import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mocktail/mocktail.dart';
import 'package:multipart_resumable/multipart_resumable.dart';
import 'package:multipart_resumable/src/data/session_store.dart';
import 'package:multipart_resumable/src/domain/repository.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class MockMultipartUploadRepository extends Mock implements MultipartUploadRepository {}

class MockUploadSessionStore extends Mock implements UploadSessionStore {}

class MockFile extends Mock implements File {}

class FakeUploadSession extends Fake implements UploadSession {}

class FakeFile extends Fake implements File {}

/// Returns the on-disk file path that [FileUploadSessionStore] would use for a
/// session keyed by [sessionPath] inside [dir]. Mirrors the private
/// `_fileForPath` logic from `session_store.dart`.
File sessionFileFor({required Directory dir, required String sessionPath}) {
  final digest = sha1.convert(utf8.encode(sessionPath)).toString();
  return File(p.join(dir.path, 'mp_$digest.json'));
}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeUploadSession());
    registerFallbackValue(FakeFile());
    registerFallbackValue(<Map<String, dynamic>>[]);
  });

  // -------------------------------------------------------------------------
  // 1. Two parallel start() calls on the same file
  // -------------------------------------------------------------------------
  group('Two parallel start() calls on the same file', () {
    test('both controllers settle and persisted session JSON parses cleanly', () async {
      final tempDir = await Directory.systemTemp.createTemp('mp_parallel_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = FileUploadSessionStore(directory: tempDir);

      // Two independent repos so both uploads run independently. Both share
      // the same session store and same file path — that is where the race
      // (if any) materialises.
      final repoA = MockMultipartUploadRepository();
      final repoB = MockMultipartUploadRepository();

      const fileSize = 5000;
      const partSize = 2000;

      final mockFile = MockFile();
      when(() => mockFile.path).thenReturn('/path/to/parallel.bin');
      when(mockFile.length).thenAnswer((_) async => fileSize);

      // Each repo returns a distinct id so the persisted session for that
      // upload can be identified.
      void wireRepo(MockMultipartUploadRepository repo, String id) {
        when(
          () => repo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': id,
            'contentType': 'application/octet-stream',
            'key': 'key-$id',
            'partSize': partSize,
          },
        );
        when(() => repo.uploadedParts(id: id)).thenAnswer((_) async => <int, String>{});
        when(
          () => repo.presignPartUrl(
            id: any(named: 'id'),
            partNumber: any(named: 'partNumber'),
          ),
        ).thenAnswer((_) async => 'http://upload/$id/part');
        when(
          () => repo.putPart(
            url: any(named: 'url'),
            file: any(named: 'file'),
            contentType: any(named: 'contentType'),
            start: any(named: 'start'),
            length: any(named: 'length'),
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) async {
          final pn = (invocation.namedArguments[#start] as int) ~/ partSize + 1;
          return 'etag-$id-$pn';
        });
        when(
          () => repo.complete(
            id: any(named: 'id'),
            parts: any(named: 'parts'),
          ),
        ).thenAnswer((_) async {});
      }

      wireRepo(repoA, 'A');
      wireRepo(repoB, 'B');

      final clientA = ResumableUploadClient(
        config: const ResumableClientConfig(baseUrl: 'http://api.test', cdnBaseUrl: 'http://cdn.test'),
        repository: repoA,
        sessionStore: store,
      );
      final clientB = ResumableUploadClient(
        config: const ResumableClientConfig(baseUrl: 'http://api.test', cdnBaseUrl: 'http://cdn.test'),
        repository: repoB,
        sessionStore: store,
      );

      // Kick off both concurrently. We never want this to throw an unhandled
      // exception even if writes interleave.
      final futA = clientA.start(file: mockFile, partSizeBytes: partSize);
      final futB = clientB.start(file: mockFile, partSizeBytes: partSize);

      final results = await Future.wait([
        futA.then((c) => c.done),
        futB.then((c) => c.done),
      ]);

      // Both controllers must settle deterministically.
      for (final r in results) {
        // Either Left(failure) or Right(success) — never throws.
        r.fold((_) {}, (_) {});
      }

      // The persisted session file (if any remains — successful flows remove
      // it via removeByPath) must contain parseable JSON. Inspect the file
      // path that *would* hold the session for `/path/to/parallel.bin`.
      final sessionFile = sessionFileFor(
        dir: tempDir,
        sessionPath: '/path/to/parallel.bin',
      );
      if (await sessionFile.exists()) {
        final raw = await sessionFile.readAsString();
        expect(
          () => jsonDecode(raw),
          returnsNormally,
          reason: 'Persisted session JSON should parse cleanly after concurrent writes',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // 2. _repo.complete() failure should remove session from disk
  // -------------------------------------------------------------------------
  group('_repo.complete() failure leaves session on disk', () {
    test('asserts removeByPath is called after complete() throws', () async {
      final mockRepo = MockMultipartUploadRepository();
      final mockStore = MockUploadSessionStore();
      final mockFile = MockFile();

      const fileSize = 5000;
      const partSize = 2000;

      when(() => mockFile.path).thenReturn('/path/to/complete_fail.bin');
      when(mockFile.length).thenAnswer((_) async => fileSize);
      when(() => mockStore.save(any())).thenAnswer((_) async {});
      when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});

      when(
        () => mockRepo.init(
          path: any(named: 'path'),
          fileSize: any(named: 'fileSize'),
        ),
      ).thenAnswer(
        (_) async => {
          'id': 'session-id',
          'contentType': 'application/octet-stream',
          'key': 'k',
          'partSize': partSize,
        },
      );
      when(() => mockRepo.uploadedParts(id: 'session-id'))
          .thenAnswer((_) async => <int, String>{});
      when(
        () => mockRepo.presignPartUrl(
          id: any(named: 'id'),
          partNumber: any(named: 'partNumber'),
        ),
      ).thenAnswer((_) async => 'http://upload/part');
      when(
        () => mockRepo.putPart(
          url: any(named: 'url'),
          file: any(named: 'file'),
          contentType: any(named: 'contentType'),
          start: any(named: 'start'),
          length: any(named: 'length'),
          onSendProgress: any(named: 'onSendProgress'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => 'etag-x');

      // complete() throws — server may have invalidated the upload.
      when(
        () => mockRepo.complete(
          id: any(named: 'id'),
          parts: any(named: 'parts'),
        ),
      ).thenThrow(
        // Use a DioException so it goes through _handleCommonErrors path.
        Exception('complete failed'),
      );

      final client = ResumableUploadClient(
        config: const ResumableClientConfig(
          baseUrl: 'http://api.test',
          cdnBaseUrl: 'http://cdn.test',
        ),
        repository: mockRepo,
        sessionStore: mockStore,
      );

      final controller = await client.start(file: mockFile, partSizeBytes: partSize);
      final result = await controller.done;

      // Sanity: the upload failed.
      expect(result.isLeft(), isTrue);

      // EXPECTED BUG: per the design goal in the task, on complete() failure
      // the cached session file should be removed so a future retry won't
      // reuse a server-invalidated upload id. resumable_uploader.dart:262
      // only calls removeByPath on success, so this assertion will fail.
      // EXPECTED BUG: complete() failure leaves the on-disk session in place,
      // so retries may reuse a server-invalidated upload id.
      verify(() => mockStore.removeByPath('/path/to/complete_fail.bin')).called(1);
    });
  });

  // -------------------------------------------------------------------------
  // 3. uploadedParts returns a part number > totalParts (stale etag leakage)
  // -------------------------------------------------------------------------
  group('uploadedParts returns a part number > totalParts', () {
    test('complete() payload pinning: does stale partNumber 99 leak?', () async {
      final mockRepo = MockMultipartUploadRepository();
      final mockStore = MockUploadSessionStore();
      final mockFile = MockFile();

      const fileSize = 5000;
      const partSize = 2000; // 3 parts: 1, 2, 3

      when(() => mockFile.path).thenReturn('/path/to/stale.bin');
      when(mockFile.length).thenAnswer((_) async => fileSize);
      when(() => mockStore.save(any())).thenAnswer((_) async {});
      when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});

      when(
        () => mockRepo.init(
          path: any(named: 'path'),
          fileSize: any(named: 'fileSize'),
        ),
      ).thenAnswer(
        (_) async => {
          'id': 'session-id',
          'contentType': 'application/octet-stream',
          'key': 'k',
          'partSize': partSize,
        },
      );
      // Server says part 1 already done AND a stale part 99 is present.
      when(() => mockRepo.uploadedParts(id: 'session-id'))
          .thenAnswer((_) async => {1: 'etag1', 99: 'stale-etag'});

      when(
        () => mockRepo.presignPartUrl(
          id: any(named: 'id'),
          partNumber: any(named: 'partNumber'),
        ),
      ).thenAnswer((_) async => 'http://upload/part');

      when(
        () => mockRepo.putPart(
          url: any(named: 'url'),
          file: any(named: 'file'),
          contentType: any(named: 'contentType'),
          start: any(named: 'start'),
          length: any(named: 'length'),
          onSendProgress: any(named: 'onSendProgress'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) async {
        final start = invocation.namedArguments[#start] as int;
        return 'etag-${start ~/ partSize + 1}';
      });

      List<Map<String, dynamic>>? capturedParts;
      when(
        () => mockRepo.complete(
          id: any(named: 'id'),
          parts: any(named: 'parts'),
        ),
      ).thenAnswer((invocation) async {
        capturedParts = List<Map<String, dynamic>>.from(
          invocation.namedArguments[#parts] as List<Map<String, dynamic>>,
        );
      });

      final client = ResumableUploadClient(
        config: const ResumableClientConfig(
          baseUrl: 'http://api.test',
          cdnBaseUrl: 'http://cdn.test',
        ),
        repository: mockRepo,
        sessionStore: mockStore,
      );

      final controller = await client.start(file: mockFile, partSizeBytes: partSize);
      await controller.done;

      expect(capturedParts, isNotNull,
          reason: 'complete() must have been invoked');

      final partNumbers = capturedParts!.map((m) => m['PartNumber'] as int).toList();

      // Pin current behaviour: the orchestrator builds the complete() payload
      // from `etags.entries`, which still contains the server's stale
      // partNumber 99. This is almost certainly undesirable — the server
      // will reject the manifest or, worse, accept it with garbage — but
      // we lock the current behaviour so a future fix is easy to detect.
      //
      // NOTE: current behaviour is NOT desirable; complete() should only
      // ever receive partNumbers in 1..totalParts.
      expect(partNumbers, contains(99),
          reason: 'Stale etag from uploadedParts leaks into complete() — '
              'pinning current (likely undesirable) behaviour');
      expect(partNumbers, containsAll(<int>[1, 2, 3]),
          reason: 'All real parts must still be included');
    });
  });

  // -------------------------------------------------------------------------
  // 4. init response with missing/wrong-type fields
  // -------------------------------------------------------------------------
  group('init response with missing/wrong-type fields', () {
    const fileSize = 5000;
    const partSize = 2000;

    late MockMultipartUploadRepository mockRepo;
    late MockUploadSessionStore mockStore;
    late MockFile mockFile;
    late ResumableUploadClient client;

    setUp(() {
      mockRepo = MockMultipartUploadRepository();
      mockStore = MockUploadSessionStore();
      mockFile = MockFile();

      when(() => mockFile.path).thenReturn('/path/to/init_shape.bin');
      when(mockFile.length).thenAnswer((_) async => fileSize);
      when(() => mockStore.save(any())).thenAnswer((_) async {});
      when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});

      client = ResumableUploadClient(
        config: const ResumableClientConfig(
          baseUrl: 'http://api.test',
          cdnBaseUrl: 'http://cdn.test',
        ),
        repository: mockRepo,
        sessionStore: mockStore,
      );
    });

    Future<void> runAndExpectUnknown(Map<String, dynamic> initResponse) async {
      when(
        () => mockRepo.init(
          path: any(named: 'path'),
          fileSize: any(named: 'fileSize'),
        ),
      ).thenAnswer((_) async => initResponse);

      final controller = await client.start(file: mockFile, partSizeBytes: partSize);
      final result = await controller.done;
      expect(result.isLeft(), isTrue);
      result.fold(
        (f) => expect(f, isA<UnknownUploadException>()),
        (_) => fail('expected UnknownUploadException'),
      );
    }

    // -- id ---------------------------------------------------------------
    test('missing id field → UnknownUploadException', () async {
      await runAndExpectUnknown({
        'contentType': 'application/octet-stream',
        'key': 'k',
        'partSize': partSize,
      });
    });

    test('id with wrong type → UnknownUploadException', () async {
      await runAndExpectUnknown({
        'id': 42,
        'contentType': 'application/octet-stream',
        'key': 'k',
        'partSize': partSize,
      });
    });

    // -- key --------------------------------------------------------------
    test('missing key field → UnknownUploadException', () async {
      await runAndExpectUnknown({
        'id': 'session-id',
        'contentType': 'application/octet-stream',
        'partSize': partSize,
      });
    });

    test('key with wrong type → UnknownUploadException', () async {
      await runAndExpectUnknown({
        'id': 'session-id',
        'contentType': 'application/octet-stream',
        'key': 7,
        'partSize': partSize,
      });
    });

    // -- contentType ------------------------------------------------------
    test('missing contentType field → UnknownUploadException', () async {
      await runAndExpectUnknown({
        'id': 'session-id',
        'key': 'k',
        'partSize': partSize,
      });
    });

    test('contentType with wrong type → UnknownUploadException', () async {
      await runAndExpectUnknown({
        'id': 'session-id',
        'contentType': 123,
        'key': 'k',
        'partSize': partSize,
      });
    });

    // -- partSize ---------------------------------------------------------
    // Missing partSize is tolerated (code path uses `as int?` with fallback),
    // so we only assert on a wrong-type value.
    test('partSize with wrong type → UnknownUploadException', () async {
      // Wire enough downstream calls so any successful path would still
      // complete — that way if the cast doesn't throw, the test would
      // fail by completing successfully rather than hanging.
      when(() => mockRepo.uploadedParts(id: any(named: 'id')))
          .thenAnswer((_) async => <int, String>{});
      when(
        () => mockRepo.presignPartUrl(
          id: any(named: 'id'),
          partNumber: any(named: 'partNumber'),
        ),
      ).thenAnswer((_) async => 'http://upload/part');
      when(
        () => mockRepo.putPart(
          url: any(named: 'url'),
          file: any(named: 'file'),
          contentType: any(named: 'contentType'),
          start: any(named: 'start'),
          length: any(named: 'length'),
          onSendProgress: any(named: 'onSendProgress'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => 'etag');
      when(
        () => mockRepo.complete(
          id: any(named: 'id'),
          parts: any(named: 'parts'),
        ),
      ).thenAnswer((_) async {});

      await runAndExpectUnknown({
        'id': 'session-id',
        'contentType': 'application/octet-stream',
        'key': 'k',
        'partSize': 'not-an-int',
      });
    });
  });
}
