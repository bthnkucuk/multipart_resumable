import 'package:multipart_resumable/multipart_resumable.dart';
import 'package:test/test.dart';

void main() {
  group('UploadController', () {
    test('done returns Right with CDN URL when complete succeeds', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')
        ..setSessionInfo(id: 'id-1', key: 'my/key')
        ..complete();

      final result = await c.done;
      expect(result.isRight(), isTrue);
      result.fold(
        (_) => fail('expected Right'),
        (url) => expect(url, 'https://cdn.example/my/key'),
      );
      expect(c.id, 'id-1');
      expect(c.key, 'my/key');
      expect(c.cdnUrl, 'https://cdn.example/my/key');
    });

    test('done returns Left with failure after completeError', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')
        ..completeError(Exception('x'), const UnknownUploadException());

      final result = await c.done;
      expect(result.isLeft(), isTrue);
      result.fold(
        (f) => expect(f, isA<UnknownUploadException>()),
        (_) => fail('expected Left'),
      );
      expect(c.id, isNull);
      expect(c.cdnUrl, isNull);
    });

    test('id and cdnUrl are null until successful completion', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')..setSessionInfo(id: 'sess', key: 'k');
      expect(c.id, isNull);
      expect(c.cdnUrl, isNull);

      c.complete();
      expect(c.id, 'sess');
      expect(c.cdnUrl, 'https://cdn.example/k');
    });

    test('complete and completeError are idempotent (first wins)', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')
        ..setSessionInfo(id: 'a', key: 'b')
        ..complete()
        ..completeError(Exception(), const UnknownUploadException());

      final result = await c.done;
      expect(result.isRight(), isTrue);
    });

    test('setSessionInfo is ignored after dispose', () {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')
        ..dispose()
        ..setSessionInfo(id: 'x', key: 'y')
        ..complete();
      // key was never set — Right URL uses null key path
      expect(c.key, isNull);
    });

    test('pause and resume toggle isPaused and emit onPausedStream', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example');
      expect(c.isPaused, isFalse);

      final events = <bool>[];
      final sub = c.onPausedStream.listen(events.add);

      c.pause();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(c.isPaused, isTrue);
      c.pause();
      expect(c.isPaused, isTrue);

      c.resume();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(c.isPaused, isFalse);
      c.resume();
      expect(c.isPaused, isFalse);

      await sub.cancel();
      expect(events, [true, false]);
    });

    test('pause/resume/cancel no-op when disposed', () {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')
        ..dispose()
        ..pause();
      expect(c.isPaused, isFalse);
      c
        ..resume()
        ..cancel();
    });

    test('cancel emits once on onCancelStream and is idempotent', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example');
      var count = 0;
      final sub = c.onCancelStream.listen((_) => count++);
      c
        ..cancel()
        ..cancel();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(count, 1);
      expect(c.isCancelRequested, isTrue);
    });

    test('isCancelRequested is false until cancel is called', () {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example');
      expect(c.isCancelRequested, isFalse);
      c.cancel();
      expect(c.isCancelRequested, isTrue);
    });

    test('dispose before complete resolves done with UnknownUploadException', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')..dispose();

      final result = await c.done;
      expect(result.isLeft(), isTrue);
      result.fold(
        (f) => expect(f, isA<UnknownUploadException>()),
        (_) => fail('expected Left after dispose'),
      );
    });

    test('dispose after successful complete preserves the success result', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')
        ..setSessionInfo(id: 'i', key: 'k')
        ..complete()
        ..dispose();

      final result = await c.done;
      expect(result.isRight(), isTrue);
      result.fold(
        (_) => fail('expected Right'),
        (url) => expect(url, 'https://cdn.example/k'),
      );
    });

    test('dispose after completeError preserves the original failure', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')
        ..completeError(Exception(), const CancelledUploadException())
        ..dispose();

      final result = await c.done;
      result.fold(
        (f) => expect(f, isA<CancelledUploadException>()),
        (_) => fail('expected Left'),
      );
    });

    test('dispose is idempotent (no double-close error)', () {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')
        ..dispose()
        ..dispose();
      expect(c.isPaused, isFalse);
    });

    test('waitWhilePaused returns immediately when not paused', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example');
      await c.waitWhilePaused().timeout(const Duration(milliseconds: 50));
    });

    test('waitWhilePaused awaits resume race-free', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')..pause();

      var resolved = false;
      final waiter = c.waitWhilePaused().then((_) => resolved = true);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(resolved, isFalse, reason: 'waiter must block while paused');

      c.resume();
      await waiter.timeout(const Duration(milliseconds: 100));
      expect(resolved, isTrue);
    });

    test('waitWhilePaused unblocks if controller is disposed while paused', () async {
      final c = UploadController(cdnBaseUrl: 'https://cdn.example')..pause();

      final waiter = c.waitWhilePaused();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      c.dispose();

      await waiter.timeout(const Duration(milliseconds: 100));
    });
  });
}
