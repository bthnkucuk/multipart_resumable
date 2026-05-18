import 'dart:io';
import 'package:dio/dio.dart';
import 'package:multipart_resumable/multipart_resumable.dart';

Future<void> main(List<String> args) async {
  const config = ResumableClientConfig(
    baseUrl: 'http://127.0.0.1:8000',
    cdnBaseUrl: 'https://cdn.example.com',
    // endpointPrefix: 'resumable-upload',
    // versionHeaderName: 'Resumable-Upload-Version',
    // versionHeaderValue: '1.0',
  );
  final client = ResumableUploadClient(config: config, dio: Dio());

  final file = File('/path/to/your/file.pdf');
  if (!await file.exists()) {
    return;
  }

  final controller = await client.start(
    file: file,
    onProgress: (sent, total) {
      // log('Progress: ${((sent / total) * 100).toStringAsFixed(2)}%');
    },
    onError: (e) {
      // log('Upload failed: $e');
    },
  );

  // Demonstration: pause after 2 seconds, then resume after 2 more seconds
  // Future.delayed(const Duration(seconds: 2), controller.pause);
  // Future.delayed(const Duration(seconds: 4), controller.resume);

  final result = await controller.done;
  result.fold(
    (l) {
      // log('Upload failed: $l');
    },
    (r) {
      // log('Upload completed: $r');
    },
  );

  controller.dispose();

  // log('Upload Key: ${controller.key}');
  // log('Upload CDN URL: ${controller.cdnUrl}');
  // log('Upload completed');
}
