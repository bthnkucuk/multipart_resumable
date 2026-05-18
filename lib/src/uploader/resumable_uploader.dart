import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken, Dio, DioException, DioExceptionType;
import 'package:path/path.dart' as p;

import '../../multipart_resumable.dart';
import '../data/http_api.dart';
import '../data/session_store.dart';
import '../domain/repository.dart';

bool _isCancellation(Object error) => error is DioException && error.type == DioExceptionType.cancel;

UploadException? _handleCommonErrors(Object error) {
  if (error is DioException) {
    if (error.response?.statusCode == 429) {
      return RateLimitExceededUploadException(code: error.response?.statusCode.toString());
    }
  }
  return null;
}

/// [ResumableUploadClient] is a client for resumable upload.
/// It is used to upload files to the server, wrapping [UploadController],
/// [UploadSessionStore], and [MultipartUploadRepository].
///
/// `clientMaxUploadSizeBytes` (passed to [start]) is the maximum file size the
/// client will accept. If the file exceeds it, the controller completes with
/// a [ClientUploadSizeLimitException].
class ResumableUploadClient {
  ResumableUploadClient({
    required ResumableClientConfig config,
    Dio? dio,
    UploadSessionStore? sessionStore,
    MultipartUploadRepository? repository,
  }) : assert(
         dio != null || repository != null,
         'Either dio or repository must be provided',
       ),
       _config = config,
       _store = sessionStore ?? FileUploadSessionStore(directory: Directory.systemTemp),
       _repo = repository ?? HttpMultipartRepository(config: config, dio: dio!);

  factory ResumableUploadClient.profileImage({
    required String baseUrl,
    required String cdnBaseUrl,
    required Dio dio,
    UploadSessionStore? sessionStore,
    MultipartUploadRepository? repository,
  }) => ResumableUploadClient(
    config: ResumableClientConfig.profileImage(baseUrl: baseUrl, cdnBaseUrl: cdnBaseUrl),
    sessionStore: sessionStore,
    repository: repository,
    dio: dio,
  );

  factory ResumableUploadClient.defaultClient({
    required String baseUrl,
    required String cdnBaseUrl,
    required Dio dio,
    UploadSessionStore? sessionStore,
    MultipartUploadRepository? repository,
  }) => ResumableUploadClient(
    config: ResumableClientConfig.defaultConfig(baseUrl: baseUrl, cdnBaseUrl: cdnBaseUrl),
    sessionStore: sessionStore,
    repository: repository,
    dio: dio,
  );

  final ResumableClientConfig _config;
  final UploadSessionStore _store;
  final MultipartUploadRepository _repo;

  Future<UploadController> start({
    required File file,
    int? clientMaxUploadSizeBytes,
    int? partSizeBytes,
    int? maxRetriesPerPart,
    int? concurrency,
    UploadProgressCallback? onProgress,
    UploadErrorCallback? onError,
    String? existingId,
  }) async {
    final controller = UploadController(cdnBaseUrl: _config.cdnBaseUrl);
    try {
      final fileSize = await file.length();

      if (clientMaxUploadSizeBytes != null && fileSize > clientMaxUploadSizeBytes) {
        controller.completeError(
          const FileIsTooLargeUploadException(),
          ClientUploadSizeLimitException(maxUploadSizeBytes: clientMaxUploadSizeBytes),
        );
        return controller;
      }

      if (fileSize == 0) {
        controller.completeError(const FileIsEmptyUploadException(), const FileIsEmptyUploadException());
        return controller;
      } else if (fileSize > _config.serverMaxUploadSizeBytes) {
        controller.completeError(const FileIsTooLargeUploadException(), const FileIsTooLargeUploadException());
        return controller;
      }
      // [name] is the logical path sent to the server (display/key only).
      // [sessionKey] is the local-cache identity — full file path so two files
      // with the same basename in different directories don't collide.
      final name = p.basename(file.path);
      final sessionKey = file.path;

      // If this would be a single-part upload, use the single PUT flow
      final effectivePartSize = partSizeBytes ?? _config.defaultPartSizeBytes;
      if (existingId == null && fileSize <= effectivePartSize) {
        try {
          final singleInit = await _repo.singleInit(path: name, fileSize: fileSize);
          final url = singleInit['url'] as String;
          final key = singleInit['key'] as String;
          final headersDynamic = (singleInit['headers'] as Map?) ?? const {};
          final headers = headersDynamic.map((k, v) => MapEntry(k.toString(), v.toString()));

          controller.setSessionInfo(id: key, key: key);

          await _repo.putObject(
            url: url,
            file: file,
            headers: headers.cast<String, String>(),
            onSendProgress: (sent, total) {
              onProgress?.call(sent, fileSize);
            },
          );

          controller.complete();
        } catch (e, st) {
          final failure = _handleCommonErrors(e) ?? const UnknownUploadException();

          controller.completeError(e, failure, st);
        }
        return controller;
      }

      // Create or load session
      UploadSession session;
      var etags = <int, String>{};

      if (existingId != null) {
        final loaded = await _store.loadByPath(sessionKey);
        if (loaded == null) {
          controller.completeError(
            StateError('Session not found for path: $sessionKey'),
            const UnknownUploadException(),
          );
          return controller;
        }
        if (loaded.id != existingId) {
          controller.completeError(
            StateError('existingId mismatch: cached session id is ${loaded.id} but $existingId was supplied'),
            const UnknownUploadException(),
          );
          return controller;
        }
        session = loaded;
        etags = Map.of(loaded.etags);
        controller.setSessionInfo(id: session.id, key: session.key);
      } else {
        final Map<String, dynamic> initResp;
        try {
          initResp = await _repo.init(path: name, fileSize: fileSize);
        } catch (e, st) {
          final failure = _handleCommonErrors(e) ?? const UnknownUploadException();
          controller.completeError(e, failure, st);
          return controller;
        }
        final id = initResp['id'] as String;
        final contentType = initResp['contentType'] as String;
        final key = initResp['key'] as String;
        final serverPartSize = (initResp['partSize'] as int?) ?? (partSizeBytes ?? _config.defaultPartSizeBytes);
        session = UploadSession(
          path: sessionKey,
          id: id,
          key: key,
          partSize: serverPartSize,
          fileSize: fileSize,
          etags: {},
          filePath: file.path,
          contentType: contentType,
        );
        await _store.save(session);
        controller.setSessionInfo(id: session.id, key: session.key);
      }

      // Sync with server about already uploaded parts
      final Map<int, String> uploaded;
      try {
        uploaded = await _repo.uploadedParts(id: session.id);
      } catch (e, st) {
        final failure = _handleCommonErrors(e) ?? const UnknownUploadException();
        controller.completeError(e, failure, st);
        return controller;
      }
      // Merge server-known part etags
      etags.addAll(uploaded);

      final effectiveMaxRetries = maxRetriesPerPart ?? _config.maxRetriesPerPart;
      final retryPolicy = RetryPolicy(maxRetries: effectiveMaxRetries, baseDelay: _config.retryBaseDelay);
      final totalBytes = session.fileSize;

      void reportProgressAbsoluteLocal(int absolute) {
        onProgress?.call(absolute, totalBytes);
      }

      // Sequential upload for v1 for simplicity; can extend to pool concurrency later
      unawaited(
        _runSequential(
          controller: controller,
          file: file,
          session: session,
          etags: etags,
          retryPolicy: retryPolicy,
          onPartUploaded: (pn, etag, newSentAbsolute) async {
            reportProgressAbsoluteLocal(newSentAbsolute);
            // persist immediately
            final updated = UploadSession(
              path: session.path,
              id: session.id,
              key: session.key,
              partSize: session.partSize,
              fileSize: session.fileSize,
              etags: {...etags, pn: etag},
              filePath: session.filePath,
              contentType: session.contentType,
            );
            await _store.save(updated);
            etags[pn] = etag;
          },
          onError: (error) async {
            try {
              onError?.call(error);
            } catch (e, st) {
              // User callback threw — never propagate; the controller is
              // about to be completed with the underlying failure anyway.
              // Log so the bug in the callback is at least discoverable.
              developer.log(
                'onError callback threw',
                name: 'multipart_resumable',
                error: e,
                stackTrace: st,
              );
            }
          },
          onCompleteAll: () async {
            try {
              final partsForComplete = etags.entries.map((e) => {'PartNumber': e.key, 'ETag': e.value}).toList()
                ..sort((a, b) {
                  if (a case {'PartNumber': final int aPartNumber}) {
                    if (b case {'PartNumber': final int bPartNumber}) {
                      return aPartNumber.compareTo(bPartNumber);
                    }
                    return 0;
                  }
                  return 0;
                });
              await _repo.complete(id: session.id, parts: partsForComplete);
              await _store.removeByPath(session.path);
              controller.complete();
            } catch (e, st) {
              final failure = _handleCommonErrors(e) ?? const UnknownUploadException();
              controller.completeError(e, failure, st);
            }
          },
          onProgressAbsolute: reportProgressAbsoluteLocal,
        ),
      );
    } catch (e, st) {
      final failure = _handleCommonErrors(e) ?? const UnknownUploadException();
      controller.completeError(e, failure, st);
    }

    return controller;
  }

  Future<void> _runSequential({
    required UploadController controller,
    required File file,
    required UploadSession session,
    required Map<int, String> etags,
    required RetryPolicy retryPolicy,
    required Future<void> Function(int partNumber, String etag, int absoluteSent) onPartUploaded,
    required Future<void> Function(Object error) onError,
    required Future<void> Function() onCompleteAll,
    required void Function(int absolute) onProgressAbsolute,
  }) async {
    try {
      final totalParts = session.totalParts;

      var absoluteSent = _calculateSentBytes(etags, session);
      onProgressAbsolute(absoluteSent);

      final cancelToken = CancelToken();
      final cancelSub = controller.onCancelStream.listen((_) {
        if (!cancelToken.isCancelled) cancelToken.cancel();
      });
      // Cancel may have been requested before our listener attached.
      if (controller.isCancelRequested && !cancelToken.isCancelled) {
        cancelToken.cancel();
      }

      try {
        for (var partNumber = 1; partNumber <= totalParts; partNumber++) {
          await controller.waitWhilePaused();

          if (cancelToken.isCancelled || controller.isCancelRequested) {
            controller.completeError(StateError('Upload cancelled'), const CancelledUploadException());
            return;
          }

          if (etags.containsKey(partNumber)) {
            continue; // already uploaded
          }

          final start = (partNumber - 1) * session.partSize;
          final remaining = session.fileSize - start;
          final length = remaining > session.partSize ? session.partSize : remaining;

          final contentType = session.contentType;

          // presign
          final url = await _repo.presignPartUrl(id: session.id, partNumber: partNumber);

          var attempt = 0;
          while (true) {
            try {
              var lastReported = 0;
              final etag = await _repo.putPart(
                url: url,
                file: file,
                contentType: contentType,
                start: start,
                length: length,
                cancelToken: cancelToken,
                onSendProgress: (sent, total) {
                  final newly = sent - lastReported;
                  lastReported = sent;
                  absoluteSent += newly;
                  onProgressAbsolute(absoluteSent);
                },
              );
              // ensure final absolute update
              if (lastReported < length) {
                absoluteSent += length - lastReported;
                onProgressAbsolute(absoluteSent);
              }
              await onPartUploaded(partNumber, etag, absoluteSent);
              break;
            } catch (e) {
              if (_isCancellation(e)) {
                controller.completeError(e, const CancelledUploadException());
                return;
              }
              if (attempt >= retryPolicy.maxRetries) {
                await onError(e);
                controller.completeError(e, const UnknownUploadException());
                return;
              }
              final delay = retryPolicy.delayForAttempt(attempt);
              await Future<void>.delayed(delay);
              attempt++;
            }
          }
        }

        await onCompleteAll();
      } finally {
        await cancelSub.cancel();
      }
    } catch (e, st) {
      if (_isCancellation(e)) {
        controller.completeError(e, const CancelledUploadException(), st);
      } else {
        controller.completeError(e, const UnknownUploadException(), st);
      }
    }
  }

  static int _calculateSentBytes(Map<int, String> etags, UploadSession session) {
    var sent = 0;
    final totalParts = session.totalParts;
    for (var pn = 1; pn <= totalParts; pn++) {
      if (etags.containsKey(pn)) {
        if (pn == totalParts) {
          final start = (pn - 1) * session.partSize;
          final remaining = session.fileSize - start;
          sent += remaining;
        } else {
          sent += session.partSize;
        }
      }
    }
    return sent;
  }
}
