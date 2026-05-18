import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;

abstract class MultipartUploadRepository {
  Future<Map<String, dynamic>> init({required String path, required int fileSize});

  /// Single-part upload initialization. Returns fields like:
  /// { method: 'PUT', url: '...', headers: { ... }, key: '...', max_size_bytes: 123 }
  Future<Map<String, dynamic>> singleInit({required String path, required int fileSize});

  Future<Map<int, String>> uploadedParts({required String id});

  Future<String> presignPartUrl({required String id, required int partNumber});

  Future<void> complete({required String id, required List<Map<String, dynamic>> parts});

  Future<String> putPart({
    required String url,
    required File file,
    required int start,
    required int length,
    required String contentType,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  });

  /// Perform a single object PUT to the provided pre-signed [url] with [headers].
  Future<void> putObject({
    required String url,
    required File file,
    required Map<String, String> headers,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  });
}
