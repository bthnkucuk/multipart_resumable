import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:multipart_resumable/multipart_resumable.dart';
import 'package:multipart_resumable/src/data/session_store.dart';
import 'package:multipart_resumable/src/domain/repository.dart';
import 'package:test/test.dart';

class MockMultipartUploadRepository extends Mock implements MultipartUploadRepository {}

class MockUploadSessionStore extends Mock implements UploadSessionStore {}

class MockFile extends Mock implements File {}

class FakeUploadSession extends Fake implements UploadSession {}

class FakeFile extends Fake implements File {}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeUploadSession());
    registerFallbackValue(FakeFile());
    registerFallbackValue(<Map<String, dynamic>>[]);
  });

  group('ResumableUploadClient progress & retry', () {
    late MockMultipartUploadRepository mockRepo;
    late MockUploadSessionStore mockStore;
    late MockFile mockFile;
    late ResumableUploadClient client;
    late ResumableClientConfig testConfig;

    setUp(() {
      mockRepo = MockMultipartUploadRepository();
      mockStore = MockUploadSessionStore();
      mockFile = MockFile();

      // Near-zero retry delay so retry-backoff tests don't sleep on wall clock.
      testConfig = const ResumableClientConfig(
        baseUrl: 'http://api.test',
        cdnBaseUrl: 'http://cdn.test',
        retryBaseDelay: Duration(milliseconds: 1),
      );

      client = ResumableUploadClient(
        config: testConfig,
        repository: mockRepo,
        sessionStore: mockStore,
      );

      when(() => mockFile.path).thenReturn('/path/to/test.bin');
      when(() => mockStore.save(any())).thenAnswer((_) async {});
      when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});
    });

    /// Wire up the standard multipart "happy" preamble (init, uploadedParts, presign).
    void stubMultipartInit({
      required int fileSize,
      required int partSize,
      String uploadId = 'upload-id-xyz',
    }) {
      when(() => mockFile.length()).thenAnswer((_) async => fileSize);
      when(
        () => mockRepo.init(
          path: any(named: 'path'),
          fileSize: any(named: 'fileSize'),
        ),
      ).thenAnswer(
        (_) async => {
          'id': uploadId,
          'contentType': 'application/octet-stream',
          'key': 'k',
          'partSize': partSize,
        },
      );
      when(() => mockRepo.uploadedParts(id: uploadId))
          .thenAnswer((_) async => <int, String>{});
      when(
        () => mockRepo.presignPartUrl(
          id: any(named: 'id'),
          partNumber: any(named: 'partNumber'),
        ),
      ).thenAnswer((_) async => 'http://upload/part');
    }

    group('Retry-cancel branch', () {
      test(
          'cancellation DioException inside retry loop completes immediately with CancelledUploadException and skips onError',
          () async {
        const fileSize = 4000;
        const partSize = 2000;
        stubMultipartInit(fileSize: fileSize, partSize: partSize);

        var putPartCalls = 0;
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
        ).thenAnswer((_) async {
          putPartCalls++;
          throw DioException(
            requestOptions: RequestOptions(path: '/p'),
            type: DioExceptionType.cancel,
          );
        });

        var onErrorCalls = 0;
        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          // High retries — should NOT be used because cancel short-circuits.
          maxRetriesPerPart: 5,
          onError: (_) {
            onErrorCalls++;
          },
        );

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<CancelledUploadException>()),
          (_) => fail('expected cancellation'),
        );
        expect(putPartCalls, 1, reason: 'cancellation must short-circuit retries');
        expect(onErrorCalls, 0,
            reason: 'onError must not be invoked for cancellation');
      });
    });

    group('Progress accounting across retries', () {
      // EXPECTED BUG: This test asserts the CORRECT invariant (sent <= total at
      // all times, final sent == total). The implementation at
      // resumable_uploader.dart:329-345 resets `lastReported = 0` per attempt
      // but does NOT rewind the shared `absoluteSent` counter, so any progress
      // reported on a failed attempt is double-counted on retry. This test is
      // expected to FAIL until the production code subtracts the prior
      // attempt's partial bytes before retrying.
      test('progress total never exceeds file size across retry of partial part', () async {
        const fileSize = 200;
        const partSize = 100;
        stubMultipartInit(fileSize: fileSize, partSize: partSize);

        // Track per-part call counts so we only fail the first part's first attempt.
        final attemptsPerStart = <int, int>{};
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
          final length = invocation.namedArguments[#length] as int;
          final cb = invocation.namedArguments[#onSendProgress]
              as void Function(int, int)?;
          final n = (attemptsPerStart[start] ?? 0) + 1;
          attemptsPerStart[start] = n;

          if (start == 0 && n == 1) {
            // Report 50 of 100 bytes, then fail with a non-cancel error.
            cb?.call(50, length);
            throw DioException(
              requestOptions: RequestOptions(path: '/p'),
              type: DioExceptionType.connectionError,
            );
          }
          // Successful attempt: report full progress and return.
          cb?.call(length, length);
          return 'etag-$start-$n';
        });

        when(
          () => mockRepo.complete(
            id: any(named: 'id'),
            parts: any(named: 'parts'),
          ),
        ).thenAnswer((_) async {});

        final progressValues = <int>[];
        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          maxRetriesPerPart: 3,
          onProgress: (sent, total) {
            expect(total, fileSize);
            progressValues.add(sent);
          },
        );

        final result = await controller.done;
        expect(result.isRight(), isTrue,
            reason: 'upload should ultimately succeed after retry');

        // Invariant 1: sent must never exceed total.
        for (final v in progressValues) {
          expect(v, lessThanOrEqualTo(fileSize),
              reason: 'progress overshoot: $progressValues');
        }
        // Invariant 2: final progress should land on exactly fileSize.
        expect(progressValues.last, fileSize,
            reason: 'final progress must equal fileSize');
      });
    });

    group('Retry backoff bounded by maxRetries', () {
      test(
          'non-cancel DioException is retried exactly maxRetries+1 times then fails as UnknownUploadException',
          () async {
        const fileSize = 4000;
        const partSize = 2000;
        stubMultipartInit(fileSize: fileSize, partSize: partSize);

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
        ).thenThrow(
          DioException(
            requestOptions: RequestOptions(path: '/p'),
            type: DioExceptionType.connectionError,
            message: 'transient',
          ),
        );

        Object? capturedError;
        var onErrorCalls = 0;
        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          maxRetriesPerPart: 3,
          onError: (e) {
            onErrorCalls++;
            capturedError = e;
          },
        );

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<UnknownUploadException>()),
          (_) => fail('expected failure after retries exhausted'),
        );
        // maxRetries=3 means 1 initial + 3 retries = 4 total attempts.
        verify(
          () => mockRepo.putPart(
            url: any(named: 'url'),
            file: any(named: 'file'),
            contentType: any(named: 'contentType'),
            start: any(named: 'start'),
            length: any(named: 'length'),
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(4);
        expect(onErrorCalls, 1,
            reason: 'onError must be invoked exactly once on terminal failure');
        expect(capturedError, isA<DioException>(),
            reason: 'underlying DioException should be passed through');
      });
    });

    group('complete() payload key shape', () {
      test(
          'parts list uses PascalCase keys (PartNumber:int, ETag:String), no extras, sorted ascending',
          () async {
        const fileSize = 5000;
        const partSize = 2000; // -> parts 1 (2000), 2 (2000), 3 (1000)
        stubMultipartInit(fileSize: fileSize, partSize: partSize);

        // Out-of-order etag responses (the uploader iterates sequentially, so
        // the only realistic out-of-orderness comes from etag VALUES not
        // PartNumbers; but we still assert sort-ascending on PartNumber).
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
          // Return etags whose lexical order differs from PartNumber order
          // (e.g. part 1 -> "zz", part 2 -> "aa", part 3 -> "mm").
          switch (start) {
            case 0:
              return 'zz-etag-1';
            case 2000:
              return 'aa-etag-2';
            case 4000:
              return 'mm-etag-3';
          }
          return 'etag';
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

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
        );
        final result = await controller.done;
        expect(result.isRight(), isTrue);

        expect(capturedParts, isNotNull);
        expect(capturedParts!.length, 3);

        // Each entry has EXACTLY {'PartNumber': int, 'ETag': String}.
        for (final entry in capturedParts!) {
          expect(entry.keys.toSet(), {'PartNumber', 'ETag'},
              reason: 'unexpected keys: ${entry.keys}');
          expect(entry['PartNumber'], isA<int>());
          expect(entry['ETag'], isA<String>());
        }

        // Sorted ascending by PartNumber.
        final partNumbers =
            capturedParts!.map((p) => p['PartNumber'] as int).toList();
        expect(partNumbers, orderedEquals([1, 2, 3]));

        // ETags correctly aligned with their PartNumbers.
        final byPn = {
          for (final p in capturedParts!) p['PartNumber'] as int: p['ETag'] as String,
        };
        expect(byPn[1], 'zz-etag-1');
        expect(byPn[2], 'aa-etag-2');
        expect(byPn[3], 'mm-etag-3');
      });
    });
  });
}
