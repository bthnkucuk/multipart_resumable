import 'package:multipart_resumable/multipart_resumable.dart';
import 'package:test/test.dart';

void main() {
  group('ResumableClientConfig defaults', () {
    test('uses documented defaults when only required fields are passed', () {
      const c = ResumableClientConfig(
        baseUrl: 'http://api',
        cdnBaseUrl: 'http://cdn',
      );
      expect(c.endpointPrefix, 'resumable-upload');
      expect(c.singlePartPrefix, 'upload');
      expect(c.versionHeaderName, 'Resumable-Upload-Version');
      expect(c.versionHeaderValue, '1.0');
      expect(c.defaultPartSizeBytes, 8 * 1024 * 1024);
      expect(c.maxRetriesPerPart, 3);
      expect(c.retryBaseDelay, const Duration(milliseconds: 500));
      expect(c.concurrency, 1);
    });

    test('throws on concurrency < 1', () {
      expect(
        () => ResumableClientConfig(
          baseUrl: 'http://api',
          cdnBaseUrl: 'http://cdn',
          concurrency: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('throws on serverMaxUploadSizeBytes <= 0', () {
      expect(
        () => ResumableClientConfig(
          baseUrl: 'http://api',
          cdnBaseUrl: 'http://cdn',
          serverMaxUploadSizeBytes: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('serverMaxUploadSizeBytes defaults to 2 GiB', () {
      const c = ResumableClientConfig(baseUrl: 'http://api', cdnBaseUrl: 'http://cdn');
      expect(c.serverMaxUploadSizeBytes, 2 * 1024 * 1024 * 1024);
    });

    test('authorizationHeaderProvider defaults to null and name to Authorization', () {
      const c = ResumableClientConfig(baseUrl: 'http://api', cdnBaseUrl: 'http://cdn');
      expect(c.authorizationHeaderProvider, isNull);
      expect(c.authorizationHeaderName, 'Authorization');
    });
  });

  group('ResumableClientConfig.profileImage', () {
    test('overrides singlePartPrefix and partSize', () {
      final c = ResumableClientConfig.profileImage(
        baseUrl: 'http://api',
        cdnBaseUrl: 'http://cdn',
      );
      expect(c.singlePartPrefix, 'upload/profile-image');
      expect(c.defaultPartSizeBytes, 16 * 1024 * 1024);
      expect(c.endpointPrefix, 'resumable-upload');
    });
  });

  group('ResumableClientConfig.defaultConfig', () {
    test('keeps standard prefixes but bumps partSize to 16 MiB', () {
      final c = ResumableClientConfig.defaultConfig(
        baseUrl: 'http://api',
        cdnBaseUrl: 'http://cdn',
      );
      expect(c.singlePartPrefix, 'upload');
      expect(c.defaultPartSizeBytes, 16 * 1024 * 1024);
    });
  });

  group('RetryPolicy', () {
    test('throws on negative maxRetries', () {
      expect(
        () => RetryPolicy(maxRetries: -1, baseDelay: const Duration(milliseconds: 100)),
        throwsA(isA<AssertionError>()),
      );
    });

    test('delayForAttempt(0) is base delay', () {
      const p = RetryPolicy(maxRetries: 3, baseDelay: Duration(milliseconds: 250));
      expect(p.delayForAttempt(0), const Duration(milliseconds: 250));
    });

    test('delayForAttempt grows as 2^attempt', () {
      const p = RetryPolicy(maxRetries: 5, baseDelay: Duration(milliseconds: 100));
      expect(p.delayForAttempt(0), const Duration(milliseconds: 100));
      expect(p.delayForAttempt(3), const Duration(milliseconds: 800));
      expect(p.delayForAttempt(5), const Duration(milliseconds: 3200));
    });
  });
}
