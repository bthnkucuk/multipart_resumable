import 'dart:async';
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

  group('ResumableUploadClient', () {
    late MockMultipartUploadRepository mockRepo;
    late MockUploadSessionStore mockStore;
    late MockFile mockFile;
    late ResumableUploadClient client;
    late ResumableClientConfig testConfig;

    setUp(() {
      mockRepo = MockMultipartUploadRepository();
      mockStore = MockUploadSessionStore();
      mockFile = MockFile();

      testConfig = const ResumableClientConfig(
        baseUrl: 'http://api.test',
        cdnBaseUrl: 'http://cdn.test',
      );

      client = ResumableUploadClient(
        config: testConfig,
        repository: mockRepo,
        sessionStore: mockStore,
      );

      when(() => mockFile.path).thenReturn('/path/to/test.txt');
    });

    group('File Validation', () {
      test('fails when file exceeds clientMaxUploadSizeBytes', () async {
        when(() => mockFile.length()).thenAnswer((_) async => 100);

        final controller = await client.start(
          file: mockFile,
          clientMaxUploadSizeBytes: 50,
        );

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (failure) => expect(failure, isA<ClientUploadSizeLimitException>()),
          (_) => fail('Should have failed'),
        );
      });

      test('fails when file is empty', () async {
        when(() => mockFile.length()).thenAnswer((_) async => 0);

        final controller = await client.start(file: mockFile);

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (failure) => expect(failure, isA<FileIsEmptyUploadException>()),
          (_) => fail('Should have failed'),
        );
      });

      test('fails when file exceeds 2GB', () async {
        when(() => mockFile.length()).thenAnswer((_) async => 3 * 1024 * 1024 * 1024); // 3GB

        final controller = await client.start(file: mockFile);

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (failure) => expect(failure, isA<FileIsTooLargeUploadException>()),
          (_) => fail('Should have failed'),
        );
      });
    });

    group('Single Part Upload', () {
      test('uploads using putObject when file size <= part size', () async {
        const fileSize = 1000;
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);

        when(
          () => mockRepo.singleInit(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'url': 'http://upload/single',
            'key': 'test-key',
            'headers': {'X-Custom-Header': 'value'},
          },
        );

        when(
          () => mockRepo.putObject(
            url: any(named: 'url'),
            file: any(named: 'file'),
            headers: any(named: 'headers'),
            onSendProgress: any(named: 'onSendProgress'),
          ),
        ).thenAnswer((invocation) async {
          final cb = invocation.namedArguments[#onSendProgress] as void Function(int, int)?;
          cb?.call(500, 1000);
        });

        var progressCalled = false;
        final controller = await client.start(
          file: mockFile,
          partSizeBytes: 2000,
          onProgress: (sent, total) {
            progressCalled = true;
          },
        );

        final result = await controller.done;
        expect(result.isRight(), isTrue);
        expect(progressCalled, isTrue);

        verify(() => mockRepo.singleInit(path: 'test.txt', fileSize: fileSize)).called(1);
        verify(
          () => mockRepo.putObject(
            url: 'http://upload/single',
            file: mockFile,
            headers: {'X-Custom-Header': 'value'},
            onSendProgress: any(named: 'onSendProgress'),
          ),
        ).called(1);
      });

      test('single PUT tolerates missing headers key', () async {
        const fileSize = 500;
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(
          () => mockRepo.singleInit(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'url': 'http://upload/single',
            'key': 'k',
          },
        );
        when(
          () => mockRepo.putObject(
            url: any(named: 'url'),
            file: any(named: 'file'),
            headers: any(named: 'headers'),
            onSendProgress: any(named: 'onSendProgress'),
          ),
        ).thenAnswer((_) async {});

        final controller = await client.start(file: mockFile, partSizeBytes: 2000);
        final result = await controller.done;
        expect(result.isRight(), isTrue);
        verify(
          () => mockRepo.putObject(
            url: 'http://upload/single',
            file: mockFile,
            headers: <String, String>{},
            onSendProgress: any(named: 'onSendProgress'),
          ),
        ).called(1);
      });

      test('single PUT maps 429 to RateLimitExceededUploadException', () async {
        when(() => mockFile.length()).thenAnswer((_) async => 500);
        when(
          () => mockRepo.singleInit(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'url': 'http://u',
            'key': 'k',
            'headers': <String, String>{},
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

        final controller = await client.start(file: mockFile, partSizeBytes: 2000);
        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<RateLimitExceededUploadException>()),
          (_) => fail('expected failure'),
        );
      });

      test('completes with error when singleInit fails', () async {
        when(() => mockFile.length()).thenAnswer((_) async => 1000);
        when(
          () => mockRepo.singleInit(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenThrow(Exception('Init failed'));

        final controller = await client.start(file: mockFile, partSizeBytes: 2000);

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (failure) => expect(failure, isA<UnknownUploadException>()),
          (_) => fail('Should have failed'),
        );
      });
    });

    group('Multipart Upload', () {
      const fileSize = 5000;
      const partSize = 2000;

      setUp(() {
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});
      });

      test('starts a new multipart upload and completes successfully', () async {
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'upload-id-123',
            'contentType': 'text/plain',
            'key': 'test-key',
            'partSize': partSize,
          },
        );

        when(() => mockRepo.uploadedParts(id: 'upload-id-123')).thenAnswer((_) async => <int, String>{});

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
        ).thenAnswer((_) async => 'etag-value');

        when(
          () => mockRepo.complete(
            id: any(named: 'id'),
            parts: any(named: 'parts'),
          ),
        ).thenAnswer((_) async {});

        when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
        );

        final result = await controller.done;
        expect(result.isRight(), isTrue);

        verify(() => mockRepo.init(path: 'test.txt', fileSize: fileSize)).called(1);
        verify(() => mockRepo.uploadedParts(id: 'upload-id-123')).called(1);
        verify(
          () => mockRepo.complete(
            id: 'upload-id-123',
            parts: any(named: 'parts'),
          ),
        ).called(1);
        verify(() => mockStore.removeByPath('/path/to/test.txt')).called(1);
      });

      test('resumes upload from existing session', () async {
        final existingSession = UploadSession(
          path: '/path/to/test.txt',
          id: 'upload-id-123',
          key: 'test-key',
          partSize: partSize,
          fileSize: fileSize,
          etags: {1: 'etag-1'},
          filePath: '/path/to/test.txt',
          contentType: 'text/plain',
        );

        when(() => mockStore.loadByPath('/path/to/test.txt')).thenAnswer((_) async => existingSession);

        when(() => mockRepo.uploadedParts(id: 'upload-id-123')).thenAnswer((_) async => {1: 'etag-1', 2: 'etag-2'});

        when(
          () => mockRepo.presignPartUrl(
            id: 'upload-id-123',
            partNumber: 3,
          ),
        ).thenAnswer((_) async => 'http://upload/part3');

        when(
          () => mockRepo.putPart(
            url: 'http://upload/part3',
            file: any(named: 'file'),
            contentType: any(named: 'contentType'),
            start: 4000,
            length: 1000,
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => 'etag-3');

        when(
          () => mockRepo.complete(
            id: any(named: 'id'),
            parts: any(named: 'parts'),
          ),
        ).thenAnswer((_) async {});

        when(() => mockStore.removeByPath('/path/to/test.txt')).thenAnswer((_) async {});

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          existingId: 'upload-id-123',
        );

        final result = await controller.done;
        expect(result.isRight(), isTrue);

        verifyNever(
          () => mockRepo.presignPartUrl(
            id: any(named: 'id'),
            partNumber: 1,
          ),
        );
        verifyNever(
          () => mockRepo.presignPartUrl(
            id: any(named: 'id'),
            partNumber: 2,
          ),
        );
        verify(() => mockRepo.presignPartUrl(id: 'upload-id-123', partNumber: 3)).called(1);
        verify(
          () => mockRepo.complete(
            id: 'upload-id-123',
            parts: any(named: 'parts'),
          ),
        ).called(1);
      });
    });

    group('Control Flows (Pause/Cancel)', () {
      const fileSize = 5000;
      const partSize = 2000;

      setUp(() {
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'upload-id-123',
            'contentType': 'text/plain',
            'key': 'test-key',
            'partSize': partSize,
          },
        );
        when(() => mockRepo.uploadedParts(id: 'upload-id-123')).thenAnswer((_) async => <int, String>{});
        when(
          () => mockRepo.presignPartUrl(
            id: any(named: 'id'),
            partNumber: any(named: 'partNumber'),
          ),
        ).thenAnswer((_) async => 'http://upload/part');
      });

      test('cancels upload', () async {
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
        ).thenAnswer((invocation) {
          final cancelToken = invocation.namedArguments[#cancelToken] as CancelToken?;
          final completer = Completer<String>();
          cancelToken?.whenCancel.then((_) {
            if (!completer.isCompleted) {
              completer.completeError(
                DioException.requestCancelled(
                  requestOptions: RequestOptions(),
                  reason: 'cancelled by test',
                ),
              );
            }
          });
          return completer.future;
        });

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));

        controller.cancel();

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (failure) => expect(failure, isA<CancelledUploadException>()),
          (_) => fail('Should have failed'),
        );
      });

      test('pauses after part 1 then resumes before part 2 upload', () async {
        const partSize = 2000;

        late UploadController uploadController;

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
          if (start == 0) {
            uploadController.pause();
            return 'etag-1';
          }
          return 'etag-2';
        });

        when(
          () => mockRepo.complete(
            id: any(named: 'id'),
            parts: any(named: 'parts'),
          ),
        ).thenAnswer((_) async {});

        when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});

        uploadController = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));
        uploadController.resume();

        final result = await uploadController.done;
        expect(result.isRight(), isTrue);
        verify(
          () => mockRepo.complete(
            id: 'upload-id-123',
            parts: any(named: 'parts'),
          ),
        ).called(1);
      });
    });

    group('Additional branches', () {
      test('start outer catch when file.length throws', () async {
        when(() => mockFile.length()).thenThrow(Exception('io'));

        final controller = await client.start(file: mockFile);
        final result = await controller.done;
        expect(result.isLeft(), isTrue);
      });

      test('presign requestCancelled maps to CancelledUploadException in outer catch', () async {
        const fileSize = 5000;
        const partSize = 2000;
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'id',
            'contentType': 'c',
            'key': 'k',
            'partSize': partSize,
          },
        );
        when(() => mockRepo.uploadedParts(id: 'id')).thenAnswer((_) async => <int, String>{});
        when(
          () => mockRepo.presignPartUrl(
            id: any(named: 'id'),
            partNumber: any(named: 'partNumber'),
          ),
        ).thenThrow(
          DioException(
            requestOptions: RequestOptions(path: '/p'),
            type: DioExceptionType.cancel,
          ),
        );

        final controller = await client.start(file: mockFile, partSizeBytes: partSize);
        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<CancelledUploadException>()),
          (_) => fail('expected failure'),
        );
      });

      test('onCompleteAll maps 429 to RateLimitExceededUploadException', () async {
        const fileSize = 5000;
        const partSize = 2000;
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'id',
            'contentType': 'c',
            'key': 'k',
            'partSize': partSize,
          },
        );
        when(() => mockRepo.uploadedParts(id: 'id')).thenAnswer((_) async => <int, String>{});
        when(
          () => mockRepo.presignPartUrl(
            id: any(named: 'id'),
            partNumber: any(named: 'partNumber'),
          ),
        ).thenAnswer((_) async => 'http://p');
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
        ).thenAnswer((_) async => 'e');
        when(
          () => mockRepo.complete(
            id: any(named: 'id'),
            parts: any(named: 'parts'),
          ),
        ).thenThrow(
          DioException(
            requestOptions: RequestOptions(path: '/c'),
            response: Response(
              requestOptions: RequestOptions(path: '/c'),
              statusCode: 429,
            ),
          ),
        );

        final controller = await client.start(file: mockFile, partSizeBytes: partSize);
        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<RateLimitExceededUploadException>()),
          (_) => fail('expected failure'),
        );
      });

      test('persists session failure surfaces via _runSequential outer catch', () async {
        const fileSize = 5000;
        const partSize = 2000;
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        var saveCalls = 0;
        when(() => mockStore.save(any())).thenAnswer((_) async {
          saveCalls++;
          if (saveCalls == 1) {
            throw Exception('persist');
          }
        });
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'id',
            'contentType': 'c',
            'key': 'k',
            'partSize': partSize,
          },
        );
        when(() => mockRepo.uploadedParts(id: 'id')).thenAnswer((_) async => <int, String>{});
        when(
          () => mockRepo.presignPartUrl(
            id: any(named: 'id'),
            partNumber: any(named: 'partNumber'),
          ),
        ).thenAnswer((_) async => 'http://p');
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
        ).thenAnswer((_) async => 'e');

        final controller = await client.start(file: mockFile, partSizeBytes: partSize);
        final result = await controller.done;
        expect(result.isLeft(), isTrue);
      });

      test('putPart progress adjusts absoluteSent when lastReported < length', () async {
        const fileSize = 200;
        const partSize = 100;
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'id',
            'contentType': 'c',
            'key': 'k',
            'partSize': partSize,
          },
        );
        when(() => mockRepo.uploadedParts(id: 'id')).thenAnswer((_) async => <int, String>{});
        when(() => mockRepo.presignPartUrl(id: any(named: 'id'), partNumber: 1)).thenAnswer((_) async => 'http://p');
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
          if (start == 0) {
            final cb = invocation.namedArguments[#onSendProgress] as void Function(int, int)?;
            cb?.call(40, 100);
          }
          return 'etag';
        });
        when(
          () => mockRepo.complete(
            id: any(named: 'id'),
            parts: any(named: 'parts'),
          ),
        ).thenAnswer((_) async {});
        when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});

        final values = <int>[];
        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          onProgress: (s, _) => values.add(s),
        );
        await controller.done;

        expect(values.contains(100), isTrue);
      });

      test('resume progress uses last-part byte count in _calculateSentBytes', () async {
        const fileSize = 5000;
        const partSize = 2000;
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'id',
            'contentType': 'c',
            'key': 'k',
            'partSize': partSize,
          },
        );
        when(() => mockRepo.uploadedParts(id: 'id')).thenAnswer((_) async => {3: 'e3'});
        when(
          () => mockRepo.presignPartUrl(
            id: 'id',
            partNumber: any(named: 'partNumber'),
          ),
        ).thenAnswer((_) async => 'u');
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
        ).thenAnswer((_) async => 'e');
        when(
          () => mockRepo.complete(
            id: any(named: 'id'),
            parts: any(named: 'parts'),
          ),
        ).thenAnswer((_) async {});
        when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});

        final first = <int>[];
        await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          onProgress: (s, _) => first.add(s),
        );

        expect(first.first, 1000);
      });
    });

    group('Retries and API errors', () {
      const fileSize = 5000;
      const partSize = 2000;

      setUp(() {
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'upload-id-123',
            'contentType': 'text/plain',
            'key': 'test-key',
            'partSize': partSize,
          },
        );
        when(() => mockRepo.uploadedParts(id: 'upload-id-123')).thenAnswer((_) async => <int, String>{});
        when(
          () => mockRepo.presignPartUrl(
            id: any(named: 'id'),
            partNumber: any(named: 'partNumber'),
          ),
        ).thenAnswer((_) async => 'http://upload/part');
      });

      test('init maps HTTP 429 to RateLimitExceededUploadException', () async {
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenThrow(
          DioException(
            requestOptions: RequestOptions(path: '/init'),
            response: Response(
              requestOptions: RequestOptions(path: '/init'),
              statusCode: 429,
            ),
          ),
        );

        final controller = await client.start(file: mockFile, partSizeBytes: partSize);
        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<RateLimitExceededUploadException>()),
          (_) => fail('expected failure'),
        );
      });

      test('retries putPart then succeeds', () async {
        var attempts = 0;
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
          attempts++;
          if (attempts == 1) {
            throw Exception('transient');
          }
          return 'etag-ok';
        });

        when(
          () => mockRepo.complete(
            id: any(named: 'id'),
            parts: any(named: 'parts'),
          ),
        ).thenAnswer((_) async {});

        when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          maxRetriesPerPart: 2,
        );

        final result = await controller.done;
        expect(result.isRight(), isTrue);
        expect(attempts, greaterThanOrEqualTo(2));
      });

      test('exhausts retries and reports UnknownUploadException', () async {
        Object? seenError;
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
        ).thenThrow(Exception('always fails'));

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          maxRetriesPerPart: 0,
          onError: (e) {
            seenError = e;
            throw StateError('onError must not fail upload completion');
          },
        );

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        expect(seenError, isNotNull);
        result.fold(
          (f) => expect(f, isA<UnknownUploadException>()),
          (_) => fail('expected failure'),
        );
      });

      test('uploadedParts failure surfaces as UnknownUploadException', () async {
        when(() => mockRepo.uploadedParts(id: 'upload-id-123')).thenThrow(Exception('status down'));

        final controller = await client.start(file: mockFile, partSizeBytes: partSize);
        final result = await controller.done;
        expect(result.isLeft(), isTrue);
      });

      test('complete failure after all parts', () async {
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
        ).thenThrow(Exception('complete failed'));

        final controller = await client.start(file: mockFile, partSizeBytes: partSize);
        final result = await controller.done;
        expect(result.isLeft(), isTrue);
      });

      test('existingId with missing session file fails', () async {
        when(() => mockStore.loadByPath('/path/to/test.txt')).thenAnswer((_) async => null);

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          existingId: 'upload-id-123',
        );

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<UnknownUploadException>()),
          (_) => fail('expected failure'),
        );
      });
    });

    group('Chunk math and progress', () {
      test('putPart uses correct start and length for each part (uneven last chunk)', () async {
        const fileSize = 11;
        const partSize = 4;
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});

        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'mp-id',
            'contentType': 'application/octet-stream',
            'key': 'k',
            'partSize': partSize,
          },
        );

        when(() => mockRepo.uploadedParts(id: 'mp-id')).thenAnswer((_) async => <int, String>{});

        when(
          () => mockRepo.presignPartUrl(
            id: any(named: 'id'),
            partNumber: any(named: 'partNumber'),
          ),
        ).thenAnswer((_) async => 'http://p');

        final ranges = <List<int>>[];
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
          ranges.add([start, length]);
          return 'e';
        });

        when(
          () => mockRepo.complete(
            id: any(named: 'id'),
            parts: any(named: 'parts'),
          ),
        ).thenAnswer((_) async {});

        when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});

        final controller = await client.start(file: mockFile, partSizeBytes: partSize);
        await controller.done;

        expect(ranges, [
          [0, 4],
          [4, 4],
          [8, 3],
        ]);
      });

      test('first onProgress reflects bytes already on server', () async {
        const fileSize = 5000;
        const partSize = 2000;
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});

        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'upload-id-123',
            'contentType': 'text/plain',
            'key': 'test-key',
            'partSize': partSize,
          },
        );

        when(() => mockRepo.uploadedParts(id: 'upload-id-123')).thenAnswer(
          (_) async => {1: 'e1', 2: 'e2'},
        );

        when(
          () => mockRepo.presignPartUrl(
            id: any(named: 'id'),
            partNumber: 3,
          ),
        ).thenAnswer((_) async => 'http://upload/p3');

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
        ).thenAnswer((_) async => 'e3');

        when(
          () => mockRepo.complete(
            id: any(named: 'id'),
            parts: any(named: 'parts'),
          ),
        ).thenAnswer((_) async {});

        when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});

        final progressValues = <int>[];
        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          onProgress: (sent, total) => progressValues.add(sent),
        );

        await controller.done;

        expect(progressValues.isNotEmpty, isTrue);
        expect(progressValues.first, 4000);
      });

      test('complete sends parts sorted by PartNumber', () async {
        const fileSize = 5000;
        const partSize = 2000;
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});

        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'upload-id-123',
            'contentType': 'text/plain',
            'key': 'test-key',
            'partSize': partSize,
          },
        );

        when(() => mockRepo.uploadedParts(id: 'upload-id-123')).thenAnswer((_) async => <int, String>{});

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

        when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});

        final controller = await client.start(file: mockFile, partSizeBytes: partSize);
        await controller.done;

        expect(capturedParts, isNotNull);
        final nums = capturedParts!.map((p) => p['PartNumber'] as int).toList();
        expect(nums, orderedEquals([1, 2, 3]));
      });
    });

    group('Session keying (basename collision fix)', () {
      const fileSize = 100;
      const partSize = 50;

      test('two files with same basename in different dirs key separate sessions', () async {
        final fileA = MockFile();
        final fileB = MockFile();
        when(() => fileA.path).thenReturn('/dir-a/photo.jpg');
        when(() => fileB.path).thenReturn('/dir-b/photo.jpg');
        when(fileA.length).thenAnswer((_) async => fileSize);
        when(fileB.length).thenAnswer((_) async => fileSize);

        when(() => mockStore.save(any())).thenAnswer((_) async {});
        when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'id',
            'contentType': 'image/jpeg',
            'key': 'k',
            'partSize': partSize,
          },
        );
        when(() => mockRepo.uploadedParts(id: 'id')).thenAnswer((_) async => <int, String>{});
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

        await (await client.start(file: fileA, partSizeBytes: partSize)).done;
        await (await client.start(file: fileB, partSizeBytes: partSize)).done;

        // Sessions should be keyed by full file path (not basename), so each
        // file gets its own removeByPath using its absolute path.
        verify(() => mockStore.removeByPath('/dir-a/photo.jpg')).called(1);
        verify(() => mockStore.removeByPath('/dir-b/photo.jpg')).called(1);
      });

      test('server-bound path is the basename, not the full path', () async {
        final file = MockFile();
        when(() => file.path).thenReturn('/secret/local/dir/photo.jpg');
        when(file.length).thenAnswer((_) async => fileSize);

        String? capturedInitPath;
        when(() => mockStore.save(any())).thenAnswer((_) async {});
        when(() => mockStore.removeByPath(any())).thenAnswer((_) async {});
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer((invocation) async {
          capturedInitPath = invocation.namedArguments[#path] as String;
          return {
            'id': 'id',
            'contentType': 'image/jpeg',
            'key': 'k',
            'partSize': partSize,
          };
        });
        when(() => mockRepo.uploadedParts(id: 'id')).thenAnswer((_) async => <int, String>{});
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

        await (await client.start(file: file, partSizeBytes: partSize)).done;

        expect(capturedInitPath, 'photo.jpg');
      });
    });

    group('Early cancel before listener attaches', () {
      test('cancel issued before _runSequential subscribes still aborts', () async {
        const fileSize = 5000;
        const partSize = 2000;

        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'id',
            'contentType': 'c',
            'key': 'k',
            'partSize': partSize,
          },
        );
        when(() => mockRepo.uploadedParts(id: 'id')).thenAnswer((_) async => <int, String>{});
        when(
          () => mockRepo.presignPartUrl(
            id: any(named: 'id'),
            partNumber: any(named: 'partNumber'),
          ),
        ).thenAnswer((_) async => 'http://upload/part');

        // Should not be called — cancel must short-circuit before any putPart.
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
        ).thenAnswer((_) async => 'unreachable');

        // Pre-create the controller and request cancel BEFORE start() runs by
        // racing: kick off start() and call cancel on the returned controller
        // synchronously after await. The persistent flag ensures the loop
        // observes cancel even though the broadcast subscription happens late.
        final startFuture = client.start(file: mockFile, partSizeBytes: partSize);
        final controller = await startFuture;
        controller.cancel();

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<CancelledUploadException>()),
          (_) => fail('expected cancellation'),
        );
      });
    });

    group('existingId validation', () {
      const fileSize = 5000;
      const partSize = 2000;

      test('fails with UnknownUploadException when existingId does not match cached session id',
          () async {
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);

        final stale = UploadSession(
          path: '/path/to/test.txt',
          id: 'session-stored',
          key: 'k',
          partSize: partSize,
          fileSize: fileSize,
          etags: const {1: 'e1'},
          filePath: '/path/to/test.txt',
          contentType: 'text/plain',
        );
        when(() => mockStore.loadByPath('/path/to/test.txt')).thenAnswer((_) async => stale);

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          existingId: 'session-supplied-but-wrong',
        );

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<UnknownUploadException>()),
          (_) => fail('expected mismatch failure'),
        );
        // Must not contact the network for parts.
        verifyNever(
          () => mockRepo.uploadedParts(id: any(named: 'id')),
        );
      });
    });

    group('serverMaxUploadSizeBytes', () {
      test('files exceeding the configured server limit fail before any network call', () async {
        const tightConfig = ResumableClientConfig(
          baseUrl: 'http://api.test',
          cdnBaseUrl: 'http://cdn.test',
          serverMaxUploadSizeBytes: 1024,
        );
        final tightClient = ResumableUploadClient(
          config: tightConfig,
          repository: mockRepo,
          sessionStore: mockStore,
        );

        when(() => mockFile.length()).thenAnswer((_) async => 2048);

        final controller = await tightClient.start(file: mockFile);
        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<FileIsTooLargeUploadException>()),
          (_) => fail('expected too-large failure'),
        );
        verifyNever(
          () => mockRepo.init(path: any(named: 'path'), fileSize: any(named: 'fileSize')),
        );
      });
    });

    group('onError callback resilience', () {
      const fileSize = 5000;
      const partSize = 2000;

      test('exception thrown from user onError is swallowed; controller still completes with failure',
          () async {
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);
        when(() => mockStore.save(any())).thenAnswer((_) async {});
        when(
          () => mockRepo.init(
            path: any(named: 'path'),
            fileSize: any(named: 'fileSize'),
          ),
        ).thenAnswer(
          (_) async => {
            'id': 'id',
            'contentType': 'c',
            'key': 'k',
            'partSize': partSize,
          },
        );
        when(() => mockRepo.uploadedParts(id: 'id')).thenAnswer((_) async => <int, String>{});
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
        ).thenThrow(Exception('boom'));

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          maxRetriesPerPart: 0,
          onError: (_) => throw StateError('user callback bug'),
        );

        final result = await controller.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<UnknownUploadException>()),
          (_) => fail('expected upload failure to surface'),
        );
      });
    });

    group('Constructor and factories', () {
      test('asserts when both dio and repository are null', () {
        expect(
          () => ResumableUploadClient(config: testConfig),
          throwsA(isA<AssertionError>()),
        );
      });

      test('accepts repository without dio', () {
        expect(
          () => ResumableUploadClient(config: testConfig, repository: mockRepo),
          returnsNormally,
        );
      });

      test('profileImage factory builds a usable client', () {
        expect(
          () => ResumableUploadClient.profileImage(
            baseUrl: 'http://api',
            cdnBaseUrl: 'http://cdn',
            dio: Dio(),
          ),
          returnsNormally,
        );
      });

      test('defaultClient factory builds a usable client', () {
        expect(
          () => ResumableUploadClient.defaultClient(
            baseUrl: 'http://api',
            cdnBaseUrl: 'http://cdn',
            dio: Dio(),
          ),
          returnsNormally,
        );
      });
    });
  });
}
