sealed class UploadException implements Exception {
  const UploadException({this.message, this.code});

  final String? message;
  final String? code;

  @override
  String toString() => message ?? code ?? runtimeType.toString();
}

final class UnknownUploadException extends UploadException {
  const UnknownUploadException({
    super.message = 'unknown_upload_failure',
    super.code = 'unknown_upload_failure',
  });
}

final class CancelledUploadException extends UploadException {
  const CancelledUploadException({
    super.message = 'upload_cancelled',
    super.code = 'upload_cancelled',
  });
}

final class FileIsEmptyUploadException extends UploadException {
  const FileIsEmptyUploadException({
    super.message = 'file_is_empty',
    super.code = 'file_is_empty',
  });
}

final class FileIsTooLargeUploadException extends UploadException {
  const FileIsTooLargeUploadException({
    super.message = 'file_is_too_large',
    super.code = 'file_is_too_large',
  });
}

final class RateLimitExceededUploadException extends UploadException {
  const RateLimitExceededUploadException({
    super.message = 'rate_limit_exceeded',
    super.code,
  });
}

final class ClientUploadSizeLimitException extends UploadException {
  const ClientUploadSizeLimitException({
    required this.maxUploadSizeBytes,
    super.message = 'client_upload_size_limit_failure',
    super.code = 'client_upload_size_limit_failure',
  });

  final int maxUploadSizeBytes;
}
