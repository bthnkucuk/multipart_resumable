import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/entities.dart' show UploadSession, decodeSessionFromJson, encodeSessionToJson;

abstract class UploadSessionStore {
  Future<void> save(UploadSession s);
  Future<UploadSession?> loadByPath(String path);
  Future<void> removeByPath(String path);
}

class FileUploadSessionStore implements UploadSessionStore {
  FileUploadSessionStore({required Directory directory}) : _dir = directory;

  final Directory _dir;

  File _fileForPath(String path) {
    final digest = sha1.convert(utf8.encode(path)).toString();
    return File(p.join(_dir.path, 'mp_$digest.json'));
  }

  @override
  Future<UploadSession?> loadByPath(String path) async {
    final f = _fileForPath(path);
    if (!await f.exists()) return null;
    try {
      return decodeSessionFromJson(await f.readAsString());
    } catch (_) {
      // Cache file is corrupt or written by an incompatible version.
      // Treat as a miss and best-effort remove so the next save can recover.
      try {
        await f.delete();
      } catch (_) {/* swallow — best-effort cleanup */}
      return null;
    }
  }

  @override
  Future<void> removeByPath(String path) async {
    final f = _fileForPath(path);
    if (await f.exists()) {
      await f.delete();
    }
  }

  @override
  Future<void> save(UploadSession s) async {
    await _dir.create(recursive: true);
    final f = _fileForPath(s.path);
    await f.writeAsString(encodeSessionToJson(s));
  }
}
