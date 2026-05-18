# multipart_resumable

Resumable multipart upload client for Dart. Pause, resume, cancel, retry — with on-disk session persistence so an interrupted upload can be resumed across process restarts.

Designed for an S3-style server contract: the package handles part chunking, parallel-safe progress accounting, ETag tracking, and exponential-backoff retries; your server issues presigned URLs.

## Features

- **Resumable** — sessions are persisted to disk; resume after app restart, network failure, or explicit pause.
- **Pause / resume / cancel** — race-free controls; `cancel()` is idempotent.
- **Automatic single-part fast path** — files smaller than `partSizeBytes` use a single PUT instead of the multipart flow.
- **Per-part retries** — exponential backoff (`baseDelay * 2^attempt`).
- **Streamed progress** — absolute `bytesSent` / `totalBytes` callbacks.
- **Typed errors** — sealed `UploadException` hierarchy (`CancelledUploadException`, `RateLimitExceededUploadException`, `FileIsTooLargeUploadException`, `FileIsEmptyUploadException`, `ClientUploadSizeLimitException`, `UnknownUploadException`).
- **Pluggable repository / session store** — swap the HTTP layer or persistence for tests or alternative backends.

## Install

```yaml
dependencies:
  multipart_resumable: ^0.3.0
  dio: ^5.9.2
```

## Server contract

The default `HttpMultipartRepository` expects these endpoints under `${baseUrl}/${endpointPrefix}` (default prefix: `resumable-upload`):

| Method | Path                                          | Body                              | Response                                                                                  |
| ------ | --------------------------------------------- | --------------------------------- | ----------------------------------------------------------------------------------------- |
| POST   | `/init`                                       | `{ path, size }`                  | `{ id, key, contentType, partSize? }`                                                     |
| GET    | `/status?id=<id>`                             | —                                 | `{ uploadedParts: [{ partNumber, etag }, ...] }`                                          |
| POST   | `/presign`                                    | `{ id, partNumber }`              | `{ url }`                                                                                 |
| POST   | `/complete`                                   | `{ id, parts: [{PartNumber, ETag}, ...] }` | `{}` (any 2xx)                                                                   |

And under `${baseUrl}/${singlePartPrefix}` (default: `upload`) for the single-PUT fast path:

| Method | Path | Body              | Response                              |
| ------ | ---- | ----------------- | ------------------------------------- |
| POST   | `/`  | `{ path, size }`  | `{ url, key, headers? }`              |

The actual byte upload (`PUT`) goes directly to the presigned URL returned by `/presign` or the single-init response — typically S3, R2, GCS, or any object store with presigned PUT support.

## Quick start

```dart
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:multipart_resumable/multipart_resumable.dart';

Future<void> main() async {
  final client = ResumableUploadClient(
    config: const ResumableClientConfig(
      baseUrl: 'https://api.example.com',
      cdnBaseUrl: 'https://cdn.example.com',
    ),
    dio: Dio(),
  );

  final controller = await client.start(
    file: File('/path/to/large.bin'),
    onProgress: (sent, total) {
      print('${(sent / total * 100).toStringAsFixed(1)}%');
    },
  );

  final result = await controller.done;
  result.fold(
    (failure) => print('Failed: ${failure.code}'),
    (cdnUrl)  => print('Uploaded: $cdnUrl'),
  );

  controller.dispose();
}
```

## Pause, resume, cancel

```dart
final controller = await client.start(file: file, onProgress: onProgress);

controller.pause();   // gracefully suspend before the next part starts
controller.resume();  // continue from where it stopped
controller.cancel();  // abort; in-flight part is cancelled via Dio CancelToken

final result = await controller.done; // Either<UploadException, String>
```

`controller.done` is a `Future<Either<UploadException, String>>`. The `Right` branch is the CDN URL (`${cdnBaseUrl}/${key}`).

## Resuming across restarts

Sessions are written to `Directory.systemTemp` (override via `sessionStore`). To resume:

```dart
final controller = await client.start(
  file: file,
  existingId: 'any-non-null', // sentinel: "load existing session for this file"
);
```

The session is keyed by the file's absolute path. If the file has been moved or deleted, the resume call fails with `UnknownUploadException`.

## Error handling

```dart
final result = await controller.done;
result.fold(
  (failure) => switch (failure) {
    CancelledUploadException()         => print('User cancelled'),
    RateLimitExceededUploadException() => print('429 — back off'),
    FileIsTooLargeUploadException()    => print('Too large for server'),
    FileIsEmptyUploadException()       => print('Empty file'),
    ClientUploadSizeLimitException(:final maxUploadSizeBytes) =>
      print('Exceeds client limit of $maxUploadSizeBytes bytes'),
    UnknownUploadException()           => print('Unknown failure'),
  },
  (url) => print('OK: $url'),
);
```

## Authorization

Attach an auth header to every API request via an async provider. The header is **never** sent to the presigned upload URL, so a Bearer token won't leak to S3:

```dart
final client = ResumableUploadClient(
  config: ResumableClientConfig(
    baseUrl: 'https://api.example.com',
    cdnBaseUrl: 'https://cdn.example.com',
    authorizationHeaderProvider: () async => 'Bearer ${await tokenStore.read()}',
  ),
  dio: Dio(),
);
```

The header name defaults to `Authorization`; override with `authorizationHeaderName`. If the provider returns `null` or empty string, no header is attached.

## Configuration

```dart
ResumableClientConfig(
  baseUrl:                     'https://api.example.com',
  cdnBaseUrl:                  'https://cdn.example.com',
  endpointPrefix:              'resumable-upload',           // default
  singlePartPrefix:            'upload',                     // default
  versionHeaderName:           'Resumable-Upload-Version',   // default
  versionHeaderValue:          '1.0',                        // default
  authorizationHeaderProvider: null,                         // optional
  authorizationHeaderName:     'Authorization',              // default
  defaultPartSizeBytes:        8 * 1024 * 1024,              // 8 MiB
  serverMaxUploadSizeBytes:    2 * 1024 * 1024 * 1024,       // 2 GiB
  maxRetriesPerPart:           3,
  retryBaseDelay:              Duration(milliseconds: 500),
);
```

Per-call overrides on `start()`: `partSizeBytes`, `maxRetriesPerPart`, `clientMaxUploadSizeBytes`.

## Testing

The constructor accepts `MultipartUploadRepository` and `UploadSessionStore` for full mockability:

```dart
ResumableUploadClient(
  config: config,
  repository: mockRepository,
  sessionStore: mockSessionStore,
);
```

When `repository` is provided, `dio` is optional.

## AI agent skill

The package ships an [Anthropic Skill](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview) at [`skills/multipart_resumable/SKILL.md`](skills/multipart_resumable/SKILL.md) that explains the API, server contract, and pitfalls to AI coding agents. Copy it into `.claude/skills/` (per-project) or `~/.claude/skills/` (global) — see [`skills/README.md`](skills/README.md) for instructions. There's also a root-level [`AGENTS.md`](AGENTS.md) for general-purpose agent compatibility (Cursor, Continue, Aider, etc.).

## License

See [LICENSE](LICENSE).
