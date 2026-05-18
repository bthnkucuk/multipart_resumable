import 'dart:io';
import 'package:dio/dio.dart';

import '../config.dart';
import '../domain/repository.dart';

class HttpMultipartRepository implements MultipartUploadRepository {
  HttpMultipartRepository({required ResumableClientConfig config, required Dio dio}) : _config = config, _dio = dio;

  final ResumableClientConfig _config;
  final Dio _dio;

  final Duration receiveTimeout = const Duration(seconds: 60);
  final Duration sendTimeout = const Duration(seconds: 600);

  Map<String, String> _baseHeaders() => {_config.versionHeaderName: _config.versionHeaderValue};

  Future<Options> _optionsWithAuth([Map<String, String>? extra]) async {
    final headers = <String, String>{..._baseHeaders(), ...?extra};
    final provider = _config.authorizationHeaderProvider;
    if (provider != null) {
      final token = await provider();
      if (token != null && token.isNotEmpty) {
        headers[_config.authorizationHeaderName] = token;
      }
    }
    return Options(headers: headers, receiveTimeout: receiveTimeout, sendTimeout: sendTimeout);
  }

  String _endpoint(String path) => '${_config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/${_config.endpointPrefix}/$path';
  String _singleRoot() => '${_config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/${_config.singlePartPrefix}';

  @override
  Future<Map<String, dynamic>> init({required String path, required int fileSize}) async {
    final resp = await _dio.post<dynamic>(
      _endpoint('init'),
      data: {'path': path, 'size': fileSize},
      options: await _optionsWithAuth(),
    );
    if (resp.data case final Map<String, dynamic> data) {
      return data;
    }
    throw StateError('Invalid response from server');
  }

  @override
  Future<Map<String, dynamic>> singleInit({required String path, required int fileSize}) async {
    final resp = await _dio.post<dynamic>(
      _singleRoot(),
      data: {'path': path, 'size': fileSize},
      options: await _optionsWithAuth(),
    );
    if (resp.data case final Map<String, dynamic> data) {
      return data;
    }
    throw StateError('Invalid response from server');
  }

  @override
  Future<Map<int, String>> uploadedParts({required String id}) async {
    final resp = await _dio.get<dynamic>(
      _endpoint('status'),
      queryParameters: {'id': id},
      options: await _optionsWithAuth(),
    );

    final data = resp.data;
    if (data case final Map<String, dynamic> data) {
      final raw = data['uploadedParts'];
      final list = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is Map<String, dynamic>) {
            list.add(e);
          } else if (e is Map) {
            list.add(Map<String, dynamic>.from(e));
          }
        }
      }
      final map = <int, String>{};
      for (final e in list) {
        final pn = (e['partNumber'] as num).toInt();
        final et = (e['etag'] as String?) ?? '';
        if (et.isNotEmpty) map[pn] = et;
      }
      return map;
    }

    throw StateError('Invalid response from server');
  }

  @override
  Future<String> presignPartUrl({required String id, required int partNumber}) async {
    final resp = await _dio.post<dynamic>(
      _endpoint('presign'),
      data: {'id': id, 'partNumber': partNumber},
      options: await _optionsWithAuth(),
    );
    if (resp.data case final Map<String, dynamic> data) {
      return data['url'] as String;
    }
    throw StateError('Invalid response from server');
  }

  @override
  Future<void> complete({required String id, required List<Map<String, dynamic>> parts}) async {
    await _dio.post<void>(_endpoint('complete'), data: {'id': id, 'parts': parts}, options: await _optionsWithAuth());
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
    final stream = file.openRead(start, start + length);
    final dio = Dio();
    final resp = await dio
        .put<void>(
          url,
          data: stream,
          options: Options(
            headers: {'Content-Length': length, 'Content-Type': contentType},
            responseType: ResponseType.plain,
            receiveTimeout: receiveTimeout,
            sendTimeout: sendTimeout,
          ),
          onSendProgress: onSendProgress,
          cancelToken: cancelToken,
        )
        .whenComplete(dio.close);
    final etag = resp.headers.value('etag') ?? resp.headers.value('ETag');
    if (etag == null || etag.isEmpty) {
      throw StateError('ETag header missing in part response');
    }
    return etag.replaceAll('"', '');
  }

  @override
  Future<void> putObject({
    required String url,
    required File file,
    required Map<String, String> headers,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final stream = file.openRead();
    final fileSize = await file.length();
    final effectiveHeaders = <String, dynamic>{...headers, 'Content-Length': fileSize}
      ..putIfAbsent('Content-Type', () => 'application/octet-stream');
    final dio = Dio();
    await dio
        .request<void>(
          url,
          data: stream,
          options: Options(
            method: 'PUT',
            headers: effectiveHeaders,
            responseType: ResponseType.plain,
            receiveTimeout: receiveTimeout,
            sendTimeout: sendTimeout,
          ),
          onSendProgress: onSendProgress,
          cancelToken: cancelToken,
        )
        .whenComplete(dio.close);
  }
}
