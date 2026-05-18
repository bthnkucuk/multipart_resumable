import 'dart:convert';
import 'dart:io';

class PartEtagEntry {
  PartEtagEntry({required this.partNumber, required this.etag});

  factory PartEtagEntry.fromJson(Map<String, dynamic> j) =>
      PartEtagEntry(partNumber: j['partNumber'] as int, etag: j['etag'] as String);
  final int partNumber;
  final String etag;

  Map<String, dynamic> toJson() => {'partNumber': partNumber, 'etag': etag};
}

class UploadSession {
  UploadSession({
    required this.path,
    required this.id, // opaque session id from server, used for subsequent calls
    required this.key, // server-generated key (for display/logging)
    required this.partSize,
    required this.fileSize,
    required this.etags,
    required this.filePath,
    required this.contentType,
  });

  factory UploadSession.fromJson(Map<String, dynamic> j) => UploadSession(
    path: j['path'] as String,
    id: j['id'] as String,
    key: j['key'] as String,
    partSize: j['partSize'] as int,
    fileSize: j['fileSize'] as int,
    etags: (j['etags'] as Map).map((k, v) => MapEntry(int.parse(k.toString()), v.toString())),
    filePath: j['filePath'] as String,
    contentType: j['contentType'] as String,
  );

  final String path;
  final String id;
  final String key;
  final int partSize;
  final int fileSize;
  final Map<int, String> etags; // partNumber -> etag
  final String filePath;
  final String contentType;

  Map<String, dynamic> toJson() => {
    'path': path,
    'id': id,
    'key': key,
    'partSize': partSize,
    'fileSize': fileSize,
    'etags': etags.map((k, v) => MapEntry(k.toString(), v)),
    'filePath': filePath,
    'contentType': contentType,
  };
}

class UploadResult {
  UploadResult({required this.id, required this.key});
  final String id;
  final String key;
}

class UploadRequest {
  UploadRequest({required this.path, required this.file, this.existingId, this.partSizeBytes});

  final String path;
  final File file;
  final String? existingId;
  final int? partSizeBytes;
}

extension UploadSessionExt on UploadSession {
  int get totalParts => (fileSize + partSize - 1) ~/ partSize;

  List<int> missingPartNumbers() {
    final missing = <int>[];
    for (var pn = 1; pn <= totalParts; pn++) {
      if (!etags.containsKey(pn)) missing.add(pn);
    }
    return missing;
  }
}

String encodeSessionToJson(UploadSession s) => jsonEncode(s.toJson());
UploadSession decodeSessionFromJson(String s) => UploadSession.fromJson(jsonDecode(s) as Map<String, dynamic>);
