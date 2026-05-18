---
name: multipart_resumable
description: Use when working with the `multipart_resumable` Dart package — adding it to a project, implementing the server contract, constructing `ResumableUploadClient`, wiring `authorizationHeaderProvider`, handling `UploadException` variants, debugging pause/resume/cancel, resuming uploads across restarts, or writing tests against `MultipartUploadRepository` / `UploadSessionStore`. Triggers on imports of `package:multipart_resumable/`, references to `ResumableUploadClient`, `UploadController`, `ResumableClientConfig`, `UploadSession`, or any of the package's exception types.
---

# multipart_resumable

Resumable multipart upload client for Dart. The package handles part chunking, ETag tracking, retries with exponential backoff, pause/resume/cancel, and on-disk session persistence so an interrupted upload can be resumed across process restarts.

The actual byte upload (`PUT`) goes directly to a presigned URL the server returns — typically S3, R2, GCS. The package never sees the storage credentials.

## When NOT to use this package

- Browser/Flutter Web: relies on `dart:io` `File`. Use the platform's native upload APIs.
- Single small files where resume isn't needed: a plain `Dio.put` is simpler.
- Servers that don't issue presigned URLs (you'd need a different upload model).

## Architecture in one diagram

```
ResumableUploadClient.start(file)
  ├─ if file is small → singleInit → PUT to presigned URL → done
  └─ otherwise:
       init           (server returns id, partSize, key)
       status         (server returns parts already uploaded — resume support)
       for each missing part:
         presign      (server returns presigned PUT URL for this part)
         PUT          (direct to S3-style storage, with CancelToken + retries)
       complete       (server finalizes the multipart upload)
```

## Server contract

Default `HttpMultipartRepository` expects these endpoints:

Under `${baseUrl}/${endpointPrefix}` (default prefix: `resumable-upload`):

| Method | Path                | Body                                       | Response                                          |
| ------ | ------------------- | ------------------------------------------ | ------------------------------------------------- |
| POST   | `/init`             | `{ path, size }`                           | `{ id, key, contentType, partSize? }`             |
| GET    | `/status?id=<id>`   | —                                          | `{ uploadedParts: [{ partNumber, etag }, ...] }`  |
| POST   | `/presign`          | `{ id, partNumber }`                       | `{ url }`                                         |
| POST   | `/complete`         | `{ id, parts: [{PartNumber, ETag}, ...] }` | any 2xx                                           |

Under `${baseUrl}/${singlePartPrefix}` (default: `upload`) for the single-PUT fast path:

| Method | Path | Body              | Response                              |
| ------ | ---- | ----------------- | ------------------------------------- |
| POST   | `/`  | `{ path, size }`  | `{ url, key, headers? }`              |

The `path` field sent to the server is the file's basename (e.g., `photo.jpg`), not the absolute local path.

## Quick start

```dart
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:multipart_resumable/multipart_resumable.dart';

final client = ResumableUploadClient(
  config: const ResumableClientConfig(
    baseUrl: 'https://api.example.com',
    cdnBaseUrl: 'https://cdn.example.com',
  ),
  dio: Dio(),
);

final controller = await client.start(
  file: File('/path/to/large.bin'),
  onProgress: (sent, total) => print('${(sent / total * 100).toStringAsFixed(1)}%'),
);

final result = await controller.done; // Either<UploadException, String>
result.fold(
  (failure) => print('Failed: ${failure.code}'),
  (cdnUrl)  => print('Uploaded: $cdnUrl'),
);

controller.dispose();
```

## Authorization

The auth header is attached to every API request (`init`, `status`, `presign`, `complete`, `singleInit`) but **never** to the presigned-URL `PUT` — so a Bearer token cannot leak to S3.

```dart
final config = ResumableClientConfig(
  baseUrl: 'https://api.example.com',
  cdnBaseUrl: 'https://cdn.example.com',
  authorizationHeaderProvider: () async => 'Bearer ${await tokenStore.read()}',
);
```

- Header name is configurable via `authorizationHeaderName` (default `Authorization`).
- If the provider returns `null` or `''`, no header is attached.
- The provider is called fresh on every API request — it can refresh tokens transparently.

## Pause / resume / cancel

```dart
final controller = await client.start(file: file, onProgress: onProgress);

controller.pause();   // suspends before the next part starts
controller.resume();  // continues from where it stopped
controller.cancel();  // aborts; in-flight part is cancelled via Dio CancelToken

final result = await controller.done;
```

Notes:

- `pause()` / `resume()` are idempotent; events on `onPausedStream` only fire on actual transitions.
- `cancel()` is idempotent and persistent — calling it before `_runSequential` subscribes still aborts (a `_cancelRequested` flag is checked at loop entry).
- `dispose()` always completes the `done` future. If called before completion it resolves with `UnknownUploadException` so awaiters never hang.

## Resuming across process restarts

Sessions are persisted by `FileUploadSessionStore` to `Directory.systemTemp` by default. The cache key is the **absolute file path** (not basename), so two files with the same name in different directories don't collide.

```dart
// First run — start the upload, capture the session id.
final controller = await client.start(file: file);
final id = controller.id; // store this somewhere durable

// Later run (process restart, app relaunch, etc.):
final resumed = await client.start(
  file: file,
  existingId: id, // must match the cached session's id
);
```

Important:

- `existingId` is **validated** against the cached session id. A mismatch fails with `UnknownUploadException`. Don't pass arbitrary non-null sentinels.
- If you don't track the id, just omit `existingId`. The session for that file path is loaded automatically by the next call to `start()` only when explicitly resuming; otherwise a fresh session is created.
- If the file was modified after the session was saved, the package does NOT detect it (yet). Don't resume after editing the file.

## Error handling

`UploadException` is `sealed` — exhaustive switch is supported:

```dart
final result = await controller.done;
result.fold(
  (failure) => switch (failure) {
    CancelledUploadException()         => print('User cancelled'),
    RateLimitExceededUploadException() => print('429 — back off'),
    FileIsTooLargeUploadException()    => print('Exceeds server limit'),
    FileIsEmptyUploadException()       => print('Empty file'),
    ClientUploadSizeLimitException(:final maxUploadSizeBytes) =>
      print('Exceeds client limit of $maxUploadSizeBytes bytes'),
    UnknownUploadException()           => print('Unknown failure'),
  },
  (url) => print('OK: $url'),
);
```

Mapping:

- HTTP 429 from any API request → `RateLimitExceededUploadException` (with `code = '429'`).
- File size > `clientMaxUploadSizeBytes` (per-call) → `ClientUploadSizeLimitException`.
- File size > `serverMaxUploadSizeBytes` (config, default 2 GiB) → `FileIsTooLargeUploadException`.
- File size 0 → `FileIsEmptyUploadException`.
- DioException with `type: cancel` → `CancelledUploadException`.
- Anything else (network, JSON shape, etc.) → `UnknownUploadException`.

User-supplied `onError` callbacks that throw are caught and logged via `dart:developer` (logger name: `multipart_resumable`); they never propagate.

## Configuration full reference

```dart
const ResumableClientConfig(
  baseUrl:                     'https://api.example.com',  // required
  cdnBaseUrl:                  'https://cdn.example.com',  // required
  endpointPrefix:              'resumable-upload',          // multipart endpoints prefix
  singlePartPrefix:            'upload',                    // single-PUT endpoint prefix
  versionHeaderName:           'Resumable-Upload-Version',
  versionHeaderValue:          '1.0',
  authorizationHeaderProvider: null,                        // async () => String?
  authorizationHeaderName:     'Authorization',
  defaultPartSizeBytes:        8 * 1024 * 1024,             // 8 MiB; server can override via init
  serverMaxUploadSizeBytes:    2 * 1024 * 1024 * 1024,      // 2 GiB hard ceiling
  maxRetriesPerPart:           3,                           // exponential backoff per part
  retryBaseDelay:              Duration(milliseconds: 500), // delay = base * 2^attempt
  concurrency:                 1,                           // currently always sequential
);
```

Per-call overrides on `start()`:

- `partSizeBytes` — override server-suggested chunk size.
- `maxRetriesPerPart` — override config retry policy.
- `clientMaxUploadSizeBytes` — fail with `ClientUploadSizeLimitException` if file exceeds this. Distinct from `serverMaxUploadSizeBytes`.
- `existingId` — see "Resuming across process restarts".
- `onProgress: (sent, total) => ...`
- `onError: (error) => ...` — fired on per-part failure before the controller completes.

## Convenience factories

```dart
// 16 MiB chunks, 'upload/profile-image' single-PUT prefix:
ResumableUploadClient.profileImage(
  baseUrl: '...',
  cdnBaseUrl: '...',
  dio: Dio(),
);

// 16 MiB chunks, default single-PUT prefix:
ResumableUploadClient.defaultClient(
  baseUrl: '...',
  cdnBaseUrl: '...',
  dio: Dio(),
);
```

## Testing

The constructor accepts `MultipartUploadRepository` and `UploadSessionStore` for full mockability. When `repository` is provided, `dio` is optional.

```dart
class MockRepo extends Mock implements MultipartUploadRepository {}
class MockStore extends Mock implements UploadSessionStore {}
class MockFile extends Mock implements File {}

final client = ResumableUploadClient(
  config: const ResumableClientConfig(baseUrl: '...', cdnBaseUrl: '...'),
  repository: MockRepo(),
  sessionStore: MockStore(),
);
```

These types are exported from `package:multipart_resumable/src/data/session_store.dart` and `package:multipart_resumable/src/domain/repository.dart` (internal paths — only stable when the consumer pins the package version).

For mocktail register fallbacks for `UploadSession`, `File`, and `List<Map<String, dynamic>>`:

```dart
class FakeUploadSession extends Fake implements UploadSession {}
class FakeFile extends Fake implements File {}

setUpAll(() {
  registerFallbackValue(FakeUploadSession());
  registerFallbackValue(FakeFile());
  registerFallbackValue(<Map<String, dynamic>>[]);
});
```

Stub mockFile.path with the absolute path you want as the session-store key:

```dart
when(() => mockFile.path).thenReturn('/path/to/photo.jpg');
when(mockFile.length).thenAnswer((_) async => 1_000_000);
```

## Pitfalls

1. **`existingId` is validated.** Pass the actual session id (capture from `controller.id`) or omit the parameter entirely.
2. **Don't share a `Dio` with auth interceptors** if you also want presigned-URL traffic clean — the package's design already isolates `putPart`/`putObject` by using bare `Dio()` instances for those, but if you wrap your `Dio` in custom interceptors for the API calls, watch what they touch.
3. **Sessions are cached on disk.** Two `start()` calls on the same file path will share the cache. To force a fresh session, call `sessionStore.removeByPath(file.path)` first.
4. **The package does not detect a modified file on resume.** If the file changed between two `start()` calls, parts will be silently mismatched on the server.
5. **`controller.done` returns `Either<UploadException, String>` (from `fpdart`).** The `Right` branch is `'$cdnBaseUrl/$key'`, not just the key.
6. **`controller.id` returns `null` until upload succeeds.** Use `controller.key` if you need it earlier.
7. **`dispose()` is idempotent and safe to call from `try/finally`.** Calling it before completion completes the `done` future with `UnknownUploadException`.

## Migration notes (when upgrading consumer code)

- **0.1.x → 0.2.x**: in-progress sessions written by 0.1.x cannot be resumed by 0.2.x (cache key changed from basename to absolute path); old session files are orphaned in temp dir. New uploads work normally.
- **0.2.x → 0.3.x**: `existingId` is now validated against the cached session id — pass the real id or omit. Hard-coded 2 GiB limit moved to config field `serverMaxUploadSizeBytes` (same default).
