import 'dart:async';

import 'package:meta/meta.dart' show immutable;

typedef AuthorizationHeaderProvider = Future<String?> Function();
typedef UploadProgressCallback = void Function(int bytesSent, int totalBytes);
typedef UploadErrorCallback = void Function(Object error);

@immutable
final class ResumableClientConfig {
  const ResumableClientConfig({
    required this.baseUrl,
    required this.cdnBaseUrl,
    this.endpointPrefix = 'resumable-upload',
    this.singlePartPrefix = 'upload',
    this.versionHeaderName = 'Resumable-Upload-Version',
    this.versionHeaderValue = '1.0',
    this.authorizationHeaderProvider,
    this.authorizationHeaderName = 'Authorization',
    this.defaultPartSizeBytes = 8 * 1024 * 1024,
    this.serverMaxUploadSizeBytes = 2 * 1024 * 1024 * 1024, // 2 GiB
    this.maxRetriesPerPart = 3,
    this.retryBaseDelay = const Duration(milliseconds: 500),
    this.concurrency = 1,
  }) : assert(concurrency >= 1, 'concurrency must be >= 1'),
       assert(
         serverMaxUploadSizeBytes > 0,
         'serverMaxUploadSizeBytes must be > 0',
       );

  factory ResumableClientConfig.profileImage({
    required String baseUrl,
    required String cdnBaseUrl,
    AuthorizationHeaderProvider? authorizationHeaderProvider,
  }) => ResumableClientConfig(
    baseUrl: baseUrl,
    cdnBaseUrl: cdnBaseUrl,
    singlePartPrefix: 'upload/profile-image',
    defaultPartSizeBytes: 1024 * 1024 * 16, // 16MB
    authorizationHeaderProvider: authorizationHeaderProvider,
  );

  factory ResumableClientConfig.defaultConfig({
    required String baseUrl,
    required String cdnBaseUrl,
    AuthorizationHeaderProvider? authorizationHeaderProvider,
  }) => ResumableClientConfig(
    baseUrl: baseUrl,
    cdnBaseUrl: cdnBaseUrl,
    defaultPartSizeBytes: 1024 * 1024 * 16, // 16MB
    authorizationHeaderProvider: authorizationHeaderProvider,
  );

  final String baseUrl;
  final String cdnBaseUrl;
  final String endpointPrefix;
  final String singlePartPrefix;
  final String versionHeaderName;
  final String versionHeaderValue;

  /// Optional async provider that returns the value to send as the
  /// authorization header on every API request (init/status/presign/complete).
  /// Not attached to presigned-URL `PUT` requests, so it can't leak to S3.
  final AuthorizationHeaderProvider? authorizationHeaderProvider;

  /// Header name used when [authorizationHeaderProvider] returns a value.
  /// Defaults to `Authorization`.
  final String authorizationHeaderName;

  /// Default chunk size in bytes. Server may override via init response.
  final int defaultPartSizeBytes;

  /// Hard server-side ceiling. Files larger than this fail with
  /// [FileIsTooLargeUploadException] before any network call. Defaults to
  /// 2 GiB (the typical S3 multipart limit).
  final int serverMaxUploadSizeBytes;

  /// Max retry attempts per part before giving up.
  final int maxRetriesPerPart;

  /// Base delay for exponential backoff. Delay = base * 2^attemptIndex.
  final Duration retryBaseDelay;

  /// Number of parts to upload concurrently. v1 supports 1..n; 1 recommended.
  final int concurrency;
}

@immutable
final class RetryPolicy {
  const RetryPolicy({required this.maxRetries, required this.baseDelay})
    : assert(maxRetries >= 0, 'maxRetries cannot be negative');

  final int maxRetries;
  final Duration baseDelay;

  Duration delayForAttempt(int attemptIndex) {
    // attemptIndex starts at 0. 0 -> base, 1 -> 2x, 2 -> 4x
    final multiplier = 1 << attemptIndex; // 2^attemptIndex
    return Duration(milliseconds: baseDelay.inMilliseconds * multiplier);
  }
}
