import 'dart:convert';
import 'dart:io';

import 'package:multipart_resumable/multipart_resumable.dart';
import 'package:test/test.dart';

void main() {
  test('UploadResult and UploadRequest hold fields', () {
    final r = UploadResult(id: 'i', key: 'k');
    expect(r.key, 'k');
    final req = UploadRequest(path: 'p', file: File('/tmp/x'), existingId: 'e', partSizeBytes: 9);
    expect(req.partSizeBytes, 9);
  });

  group('PartEtagEntry', () {
    test('roundtrips json', () {
      final e = PartEtagEntry(partNumber: 2, etag: '"ab"');
      final j = e.toJson();
      expect(PartEtagEntry.fromJson(j).partNumber, 2);
      expect(PartEtagEntry.fromJson(j).etag, '"ab"');
    });
  });

  group('UploadSession', () {
    test('roundtrips json with string etags keys', () {
      final s = UploadSession(
        path: 'a.txt',
        id: 'id1',
        key: 'k1',
        partSize: 100,
        fileSize: 250,
        etags: {1: 'e1', 3: 'e3'},
        filePath: '/tmp/a.txt',
        contentType: 'text/plain',
      );
      final json = s.toJson();
      final decoded = UploadSession.fromJson(json);
      expect(decoded.path, s.path);
      expect(decoded.etags, {1: 'e1', 3: 'e3'});
    });

    test('fromJson parses etags with int-like keys', () {
      final m = {
        'path': 'p',
        'id': 'i',
        'key': 'k',
        'partSize': 10,
        'fileSize': 25,
        'etags': {'1': 'a', '2': 'b'},
        'filePath': '/p',
        'contentType': 'application/octet-stream',
      };
      final s = UploadSession.fromJson(m);
      expect(s.etags, {1: 'a', 2: 'b'});
    });
  });

  group('encodeSessionToJson / decodeSessionFromJson', () {
    test('roundtrip', () {
      final s = UploadSession(
        path: 'x.bin',
        id: 'i',
        key: 'k',
        partSize: 8,
        fileSize: 10,
        etags: const {1: 't'},
        filePath: '/x',
        contentType: 'application/octet-stream',
      );
      final wire = encodeSessionToJson(s);
      expect(jsonDecode(wire), isA<Map<String, dynamic>>());
      expect(decodeSessionFromJson(wire).id, 'i');
    });
  });

  group('UploadSessionExt', () {
    test('totalParts ceil division', () {
      final s = UploadSession(
        path: 'p',
        id: 'i',
        key: 'k',
        partSize: 4,
        fileSize: 10,
        etags: const {},
        filePath: '/p',
        contentType: 'c',
      );
      expect(s.totalParts, 3);
    });

    test('totalParts exact multiple', () {
      final s = UploadSession(
        path: 'p',
        id: 'i',
        key: 'k',
        partSize: 5,
        fileSize: 10,
        etags: const {},
        filePath: '/p',
        contentType: 'c',
      );
      expect(s.totalParts, 2);
    });

    test('missingPartNumbers lists gaps in order', () {
      final s = UploadSession(
        path: 'p',
        id: 'i',
        key: 'k',
        partSize: 2,
        fileSize: 7,
        etags: const {2: 'b'},
        filePath: '/p',
        contentType: 'c',
      );
      expect(s.totalParts, 4);
      expect(s.missingPartNumbers(), [1, 3, 4]);
    });
  });
}
