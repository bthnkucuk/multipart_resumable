import 'package:multipart_resumable/src/domain/exceptions.dart';
import 'package:test/test.dart';

void main() {
  group('UploadException subtypes carry expected code/message', () {
    test('UnknownUploadException', () {
      const failure = UnknownUploadException();
      expect(failure.code, 'unknown_upload_failure');
      expect(failure.message, 'unknown_upload_failure');
      expect(failure, isA<UploadException>());
    });

    test('CancelledUploadException', () {
      const failure = CancelledUploadException();
      expect(failure.code, 'upload_cancelled');
      expect(failure.message, 'upload_cancelled');
    });

    test('FileIsEmptyUploadException', () {
      const failure = FileIsEmptyUploadException();
      expect(failure.code, 'file_is_empty');
      expect(failure.message, 'file_is_empty');
    });

    test('FileIsTooLargeUploadException', () {
      const failure = FileIsTooLargeUploadException();
      expect(failure.code, 'file_is_too_large');
      expect(failure.message, 'file_is_too_large');
    });

    test('RateLimitExceededUploadException forwards http status code', () {
      const failure = RateLimitExceededUploadException(code: '429');
      expect(failure.code, '429');
      expect(failure.message, 'rate_limit_exceeded');
    });
  });

  group('ClientUploadSizeLimitException', () {
    test('exposes maxUploadSizeBytes', () {
      const failure = ClientUploadSizeLimitException(
        maxUploadSizeBytes: 5 * 1024 * 1024,
      );
      expect(failure.maxUploadSizeBytes, 5 * 1024 * 1024);
      expect(failure.code, 'client_upload_size_limit_failure');
    });
  });

  test('UploadException exhaustive switch maps each subtype to its tag', () {
    String tag(UploadException f) => switch (f) {
      UnknownUploadException() => 'unknown',
      CancelledUploadException() => 'cancelled',
      FileIsEmptyUploadException() => 'empty',
      FileIsTooLargeUploadException() => 'too_large',
      RateLimitExceededUploadException() => 'rate_limit',
      ClientUploadSizeLimitException() => 'size_limit',
    };

    expect(tag(const UnknownUploadException()), 'unknown');
    expect(tag(const CancelledUploadException()), 'cancelled');
    expect(tag(const FileIsEmptyUploadException()), 'empty');
    expect(tag(const FileIsTooLargeUploadException()), 'too_large');
    expect(tag(const RateLimitExceededUploadException()), 'rate_limit');
    expect(
      tag(const ClientUploadSizeLimitException(maxUploadSizeBytes: 1)),
      'size_limit',
    );
  });
}
