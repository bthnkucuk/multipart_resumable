import 'dart:io';

import 'package:multipart_resumable/multipart_resumable.dart';
import 'package:multipart_resumable/src/data/session_store.dart';
import 'package:test/test.dart';

void main() {
  group('FileUploadSessionStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('mp_sess_');
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('save loadByPath removeByPath roundtrip', () async {
      final store = FileUploadSessionStore(directory: dir);
      final s = UploadSession(
        path: 'my/file/name.txt',
        id: 'sid',
        key: 'key1',
        partSize: 1000,
        fileSize: 5000,
        etags: const {1: 'a'},
        filePath: '/tmp/x',
        contentType: 'text/plain',
      );

      await store.save(s);
      final loaded = await store.loadByPath('my/file/name.txt');
      expect(loaded, isNotNull);
      expect(loaded!.id, 'sid');
      expect(loaded.etags[1], 'a');

      await store.removeByPath('my/file/name.txt');
      expect(await store.loadByPath('my/file/name.txt'), isNull);
    });

    test('loadByPath returns null when file missing', () async {
      final store = FileUploadSessionStore(directory: dir);
      expect(await store.loadByPath('nope'), isNull);
    });

    test('removeByPath is safe when file missing', () async {
      final store = FileUploadSessionStore(directory: dir);
      await expectLater(store.removeByPath('ghost'), completes);
    });

    test('save creates the directory if it did not exist', () async {
      final nested = Directory('${dir.path}/nested/inner');
      final store = FileUploadSessionStore(directory: nested);
      final s = UploadSession(
        path: 'p',
        id: 'i',
        key: 'k',
        partSize: 1,
        fileSize: 1,
        etags: const {},
        filePath: '/p',
        contentType: 'c',
      );
      await store.save(s);
      expect(await nested.exists(), isTrue);
    });

    test('two paths with same basename do not collide', () async {
      final store = FileUploadSessionStore(directory: dir);
      final a = UploadSession(
        path: '/dir-a/photo.jpg',
        id: 'idA',
        key: 'kA',
        partSize: 1,
        fileSize: 1,
        etags: const {},
        filePath: '/dir-a/photo.jpg',
        contentType: 'image/jpeg',
      );
      final b = UploadSession(
        path: '/dir-b/photo.jpg',
        id: 'idB',
        key: 'kB',
        partSize: 1,
        fileSize: 1,
        etags: const {},
        filePath: '/dir-b/photo.jpg',
        contentType: 'image/jpeg',
      );
      await store.save(a);
      await store.save(b);

      expect((await store.loadByPath('/dir-a/photo.jpg'))!.id, 'idA');
      expect((await store.loadByPath('/dir-b/photo.jpg'))!.id, 'idB');
    });

    test('loadByPath returns null and removes the file when contents are corrupt', () async {
      final store = FileUploadSessionStore(directory: dir);
      final s = UploadSession(
        path: '/some/file.bin',
        id: 'i',
        key: 'k',
        partSize: 1,
        fileSize: 1,
        etags: const {},
        filePath: '/some/file.bin',
        contentType: 'c',
      );
      await store.save(s);
      // Corrupt the file the store just wrote.
      final files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      await files.first.writeAsString('not valid json');

      // New behavior: corrupt cache file is treated as a miss and best-effort deleted.
      expect(await store.loadByPath('/some/file.bin'), isNull);
      expect(dir.listSync(), isEmpty);
    });
  });
}
