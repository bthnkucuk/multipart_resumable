import 'dart:async';

import 'package:fpdart/fpdart.dart';
import 'package:meta/meta.dart';

import '../domain/exceptions.dart' show UnknownUploadException, UploadException;

class UploadController {
  UploadController({required String cdnBaseUrl}) : _cdnBaseUrl = cdnBaseUrl;

  final String _cdnBaseUrl;
  final _pauseController = StreamController<bool>.broadcast();
  final _cancelController = StreamController<void>.broadcast();
  final Completer<void> _done = Completer<void>();
  bool _isDisposed = false;

  Stream<bool> get onPausedStream => _pauseController.stream;
  Stream<void> get onCancelStream => _cancelController.stream;
  Future<Either<UploadException, String>> get done async {
    await _done.future;
    if (!_completedSuccessfully) {
      return Left(_failure ?? const UnknownUploadException());
    }
    final k = _key;
    if (k == null) return const Left(UnknownUploadException());
    return Right('$_cdnBaseUrl/$k');
  }

  bool _paused = false;
  Completer<void>? _pauseWaiter;
  bool get isPaused => _paused;

  bool _cancelRequested = false;

  /// True once [cancel] has been called. Persistent — set even if no listener
  /// was attached to [onCancelStream] yet, so the uploader's loop can observe
  /// cancellation that was requested before it subscribed.
  @internal
  bool get isCancelRequested => _cancelRequested;

  bool _completedSuccessfully = false;

  UploadException? _failure;

  Object? _originalError;
  StackTrace? _originalStackTrace;

  /// The underlying error passed to [completeError], if any. Cleared on a
  /// successful [complete].
  Object? get originalError => _originalError;

  /// The stack trace passed to [completeError], if any. Cleared on a
  /// successful [complete].
  StackTrace? get originalStackTrace => _originalStackTrace;

  String? _key;
  String? _id;
  String? get key => _key;
  String? get id {
    if (!_completedSuccessfully) return null;
    return _id;
  }

  String? get cdnUrl {
    if (!_completedSuccessfully) return null;
    final k = _key;
    if (k == null) return null;
    return '$_cdnBaseUrl/$k';
  }

  void setSessionInfo({required String id, required String key}) {
    if (_isDisposed) return;
    _id = id;
    _key = key;
  }

  void pause() {
    if (_paused) return;
    if (_isDisposed) return;
    _paused = true;
    _pauseWaiter ??= Completer<void>();
    _pauseController.add(true);
  }

  void resume() {
    if (!_paused) return;
    if (_isDisposed) return;
    _paused = false;
    final waiter = _pauseWaiter;
    _pauseWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _pauseController.add(false);
  }

  /// Race-free pause wait. Returns immediately if not paused; otherwise awaits
  /// the next [resume] call.
  @internal
  Future<void> waitWhilePaused() async {
    while (_paused && !_isDisposed) {
      final waiter = _pauseWaiter ??= Completer<void>();
      await waiter.future;
    }
  }

  void cancel() {
    if (_isDisposed) return;
    if (_cancelRequested) return;
    _cancelRequested = true;
    _cancelController.add(null);
  }

  void complete() {
    if (!_done.isCompleted) {
      _completedSuccessfully = true;
      _originalError = null;
      _originalStackTrace = null;
      _done.complete();
    }
  }

  void completeError(Object error, UploadException failure, [StackTrace? st]) {
    if (_done.isCompleted) return;
    _completedSuccessfully = false;
    _failure = failure;
    _originalError = error;
    _originalStackTrace = st;
    // Never throw: complete the future normally so callers of `done` receive Left(failure).
    _done.complete();
  }

  void dispose() {
    if (_isDisposed) return;
    // Cancel any in-flight work BEFORE closing the cancel controller, so the
    // uploader's onCancelStream subscription still receives the event.
    if (!_cancelRequested) {
      _cancelRequested = true;
      _cancelController.add(null);
    }
    _isDisposed = true;
    if (!_done.isCompleted) {
      _completedSuccessfully = false;
      _failure ??= const UnknownUploadException();
      _done.complete();
    }
    final waiter = _pauseWaiter;
    _pauseWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _pauseController.close();
    _cancelController.close();
  }
}
