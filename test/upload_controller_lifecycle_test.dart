import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:mocktail/mocktail.dart';
import 'package:multipart_resumable/multipart_resumable.dart';
import 'package:multipart_resumable/src/data/session_store.dart';
import 'package:multipart_resumable/src/domain/repository.dart';
import 'package:test/test.dart';

class _MockFile extends Mock implements File {}

/// Programmable in-memory repository so tests can suspend any [putPart]
/// indefinitely and observe the [CancelToken] handed to it.
class _ControllableRepo implements MultipartUploadRepository {
  _ControllableRepo({
    required this.initResponse,
    Map<int, String>? alreadyUploaded,
  }) : _alreadyUploaded = alreadyUploaded ?? const <int, String>{};

  final Map<String, dynamic> initResponse;
  final Map<int, String> _alreadyUploaded;

  /// Per-part gates. Each completer, once resolved, yields the etag (or
  /// throws) for that part's `putPart` call. If a part has no gate the
  /// repository returns an auto-generated etag immediately.
  final Map<int, Completer<String>> partGates = {};

  /// CancelToken captured per part for inspection.
  final Map<int, CancelToken> seenCancelTokens = {};

  /// `(partNumber, onSendProgress)` recorded so a test can simulate progress.
  final Map<int, void Function(int, int)?> seenProgressCb = {};

  int completeCalls = 0;
  int initCalls = 0;
  int uploadedPartsCalls = 0;
  int singleInitCalls = 0;

  Completer<String> gateFor(int partNumber) =>
      partGates.putIfAbsent(partNumber, Completer<String>.new);

  @override
  Future<Map<String, dynamic>> init({
    required String path,
    required int fileSize,
  }) async {
    initCalls++;
    return initResponse;
  }

  @override
  Future<Map<String, dynamic>> singleInit({
    required String path,
    required int fileSize,
  }) async {
    singleInitCalls++;
    throw UnimplementedError();
  }

  @override
  Future<Map<int, String>> uploadedParts({required String id}) async {
    uploadedPartsCalls++;
    return Map<int, String>.from(_alreadyUploaded);
  }

  @override
  Future<String> presignPartUrl({
    required String id,
    required int partNumber,
  }) async {
    return 'https://presigned.example/part/$partNumber';
  }

  @override
  Future<void> complete({
    required String id,
    required List<Map<String, dynamic>> parts,
  }) async {
    completeCalls++;
  }

  @override
  Future<String> putPart({
    required String url,
    required File file,
    required int start,
    required int length,
    required String contentType,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    // Infer part number from the URL we returned in [presignPartUrl].
    final partNumber = int.parse(url.split('/').last);
    seenCancelTokens[partNumber] = cancelToken!;
    seenProgressCb[partNumber] = onSendProgress;
    final gate = partGates[partNumber];
    if (gate == null) {
      // No suspension requested — finish immediately.
      return 'etag-$partNumber';
    }
    return gate.future;
  }

  @override
  Future<void> putObject({
    required String url,
    required File file,
    required Map<String, String> headers,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    throw UnimplementedError();
  }
}

/// In-memory session store — avoids touching the real filesystem.
class _InMemorySessionStore implements UploadSessionStore {
  final Map<String, UploadSession> _byPath = {};
  int saves = 0;

  @override
  Future<UploadSession?> loadByPath(String path) async => _byPath[path];

  @override
  Future<void> removeByPath(String path) async {
    _byPath.remove(path);
  }

  @override
  Future<void> save(UploadSession s) async {
    saves++;
    _byPath[s.path] = s;
  }
}

void main() {
  const cdnBaseUrl = 'https://cdn.example';

  group('UploadController.completeError parameter handling', () {
    test(
      'completeError exposes the original error and stackTrace via '
      'controller.originalError / controller.originalStackTrace',
      () async {
        final c = UploadController(cdnBaseUrl: cdnBaseUrl);
        final originalError = StateError('root-cause-sentinel-xyz');
        final originalSt = StackTrace.current;
        const failure = UnknownUploadException();

        c.completeError(originalError, failure, originalSt);

        final result = await c.done;
        expect(result.isLeft(), isTrue);

        result.fold(
          (f) => expect(f, same(failure)),
          (_) => fail('expected Left'),
        );

        final left = result.fold<UploadException>((f) => f, (_) => failure);

        final candidates = <Object?>[
          left,
          left.message,
          left.code,
          c.id,
          c.key,
          c.cdnUrl,
          c.isPaused,
          c.isCancelRequested,
          c.originalError,
          c.originalStackTrace?.toString(),
        ];

        final exposed = candidates.any(
          (v) => v != null && v.toString().contains('root-cause-sentinel-xyz'),
        );

        expect(
          exposed,
          isTrue,
          reason:
              'controller.originalError / originalStackTrace must surface the '
              'underlying cause passed to completeError so telemetry and crash '
              'reporters can recover it.',
        );
      },
    );
  });

  group('UploadController.dispose mid-upload', () {
    setUpAll(() {
      registerFallbackValue(CancelToken());
    });

    test(
      'EXPECTED BUG: dispose() does not cancel the in-flight putPart '
      'CancelToken — outstanding Dio requests keep running after dispose',
      () async {
        final mockFile = _MockFile();
        when(() => mockFile.path).thenReturn('/tmp/lifecycle.bin');
        when(() => mockFile.length()).thenAnswer((_) async => 5000);

        final repo = _ControllableRepo(
          initResponse: const {
            'id': 'sess-1',
            'contentType': 'application/octet-stream',
            'key': 'k1',
            'partSize': 2000,
          },
        );
        // Hold part 1 forever so dispose() lands while putPart is in-flight.
        repo.gateFor(1);

        final store = _InMemorySessionStore();
        final client = ResumableUploadClient(
          config: const ResumableClientConfig(
            baseUrl: 'http://api.test',
            cdnBaseUrl: cdnBaseUrl,
          ),
          repository: repo,
          sessionStore: store,
        );

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: 2000,
        );

        // Yield enough microtasks for the unawaited _runSequential loop to
        // reach `await _repo.putPart(...)` and subscribe to onCancelStream.
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          repo.seenCancelTokens[1],
          isNotNull,
          reason: 'putPart for part 1 must have started before dispose()',
        );
        final cancelToken = repo.seenCancelTokens[1]!;
        expect(cancelToken.isCancelled, isFalse);

        controller.dispose();

        // Let any cancel propagation happen.
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          cancelToken.isCancelled,
          isTrue,
          reason:
              'dispose() should abort outstanding I/O. Today it only closes '
              'its stream controllers (upload_controller.dart 116-129); the '
              'CancelToken handed to Dio stays alive, so the HTTP request '
              'keeps running and the byte buffer it holds leaks until the '
              'server returns. Fix: dispose() should call cancel() (or emit '
              'on _cancelController before closing it).',
        );

        // Drain the gated part so the unawaited loop can exit cleanly and
        // the test does not leak a pending future.
        if (!repo.partGates[1]!.isCompleted) {
          repo.partGates[1]!.completeError(StateError('aborted by dispose'));
        }
      },
    );

    test(
      'dispose() before any progress resolves done with UnknownUploadException',
      () async {
        final c = UploadController(cdnBaseUrl: cdnBaseUrl)..dispose();
        final result = await c.done;
        expect(result.isLeft(), isTrue);
        result.fold(
          (f) => expect(f, isA<UnknownUploadException>()),
          (_) => fail('expected Left after dispose'),
        );
      },
    );
  });

  group('UploadController.pause mid-part', () {
    setUpAll(() {
      registerFallbackValue(CancelToken());
    });

    test(
      'pause() after part 1 — part 2 putPart stalls, progress does not '
      'regress, resume() lets the upload finish',
      () async {
        const fileSize = 6000;
        const partSize = 2000; // 3 parts

        final mockFile = _MockFile();
        when(() => mockFile.path).thenReturn('/tmp/three-parts.bin');
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);

        final repo = _ControllableRepo(
          initResponse: const {
            'id': 'sess-3p',
            'contentType': 'application/octet-stream',
            'key': 'k3p',
            'partSize': partSize,
          },
        );
        // Suspend part 2 until we resume. Parts 1 and 3 finish immediately.
        final part2Gate = repo.gateFor(2);

        final store = _InMemorySessionStore();
        final progress = <int>[];

        final client = ResumableUploadClient(
          config: const ResumableClientConfig(
            baseUrl: 'http://api.test',
            cdnBaseUrl: cdnBaseUrl,
          ),
          repository: repo,
          sessionStore: store,
        );

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
          onProgress: (sent, _) => progress.add(sent),
        );

        // Wait until part 1 has been persisted (so we know the loop is now
        // sitting on part 2's putPart) — bounded by a turn count, not time.
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(Duration.zero);
          if (store.saves >= 2) break; // 1 init save + 1 after-part-1 save
        }
        expect(
          store.saves,
          greaterThanOrEqualTo(2),
          reason: 'part 1 must have been persisted before pause()',
        );
        expect(repo.seenCancelTokens.containsKey(2), isTrue);

        final progressAfterPart1 = List<int>.from(progress);
        final lastProgressBeforePause =
            progressAfterPart1.isEmpty ? 0 : progressAfterPart1.last;

        controller.pause();
        expect(controller.isPaused, isTrue);

        // Even though we pause, the part-2 putPart is already in-flight and
        // suspended on its gate. While paused, no NEW part should start and
        // no progress regression should occur.
        for (var i = 0; i < 30; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(
          progress.last,
          greaterThanOrEqualTo(lastProgressBeforePause),
          reason: 'progress must be monotonically non-decreasing across pause',
        );

        // Release part 2 and then resume — the loop must be parked at
        // waitWhilePaused before starting part 3.
        if (!part2Gate.isCompleted) part2Gate.complete('etag-2');

        // Give the loop time to come back to waitWhilePaused for part 3.
        for (var i = 0; i < 30; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        // Part 3 must not have started yet (no cancelToken captured for it).
        expect(
          repo.seenCancelTokens.containsKey(3),
          isFalse,
          reason: 'paused loop must not start part 3',
        );

        controller.resume();
        expect(controller.isPaused, isFalse);

        final result = await controller.done.timeout(
          const Duration(seconds: 2),
        );
        expect(result.isRight(), isTrue);

        // Sanity: progress sequence is monotonically non-decreasing overall.
        for (var i = 1; i < progress.length; i++) {
          expect(
            progress[i],
            greaterThanOrEqualTo(progress[i - 1]),
            reason: 'progress regressed at index $i: $progress',
          );
        }
        expect(repo.completeCalls, 1);
      },
    );

    test(
      'pause() then immediate resume() in the same microtask still lets '
      'the upload complete (race-during-await on _pauseWaiter)',
      () async {
        const fileSize = 4000;
        const partSize = 2000; // 2 parts

        final mockFile = _MockFile();
        when(() => mockFile.path).thenReturn('/tmp/race.bin');
        when(() => mockFile.length()).thenAnswer((_) async => fileSize);

        final repo = _ControllableRepo(
          initResponse: const {
            'id': 'sess-race',
            'contentType': 'application/octet-stream',
            'key': 'kr',
            'partSize': partSize,
          },
        );
        // No gates — both parts finish immediately.

        final store = _InMemorySessionStore();
        final client = ResumableUploadClient(
          config: const ResumableClientConfig(
            baseUrl: 'http://api.test',
            cdnBaseUrl: cdnBaseUrl,
          ),
          repository: repo,
          sessionStore: store,
        );

        final controller = await client.start(
          file: mockFile,
          partSizeBytes: partSize,
        );

        // Fire pause and resume back-to-back synchronously, before the
        // uploader's loop has reached its next `waitWhilePaused` call. This
        // exercises the "_pauseWaiter set up during await" path at lines
        // 87-92 — the loop may enter waitWhilePaused after resume() already
        // cleared _pauseWaiter to null.
        controller
          ..pause()
          ..resume();

        final result = await controller.done.timeout(
          const Duration(seconds: 2),
        );
        expect(result.isRight(), isTrue);
        expect(repo.completeCalls, 1);
        expect(controller.isPaused, isFalse);
      },
    );
  });
}
