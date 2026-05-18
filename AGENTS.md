# AGENTS.md

Guide for AI coding agents working with the `multipart_resumable` Dart package.

## What this package is

Resumable multipart upload client for Dart. Clients call `ResumableUploadClient.start(file)`, the package handles part chunking, retries, ETag tracking, pause/resume/cancel, and on-disk session persistence. Byte uploads go directly to a server-issued presigned URL (S3 / R2 / GCS style) — the package never sees storage credentials.

## Required reading before generating code

The full API reference, server contract, configuration, error handling, testing patterns, and pitfalls live in **[`skills/multipart_resumable/SKILL.md`](skills/multipart_resumable/SKILL.md)**. Load that file before writing or modifying code that uses this package.

If you're using Claude Code, the skill will auto-load when imports of `package:multipart_resumable/...` appear in the workspace, provided you've copied `skills/multipart_resumable/` into `.claude/skills/`. See [`skills/README.md`](skills/README.md) for installation.

## Quick reference (for short tasks)

```dart
final client = ResumableUploadClient(
  config: const ResumableClientConfig(
    baseUrl: 'https://api.example.com',
    cdnBaseUrl: 'https://cdn.example.com',
    // optional: authorizationHeaderProvider: () async => 'Bearer ...',
  ),
  dio: Dio(),
);

final controller = await client.start(
  file: File(path),
  onProgress: (sent, total) {/* ... */},
);

final result = await controller.done; // Either<UploadException, String>
controller.dispose();
```

Pause/resume/cancel: `controller.pause()`, `controller.resume()`, `controller.cancel()`.

Resume across restarts: capture `controller.id` after first `start()`, pass it as `existingId:` on the next call. The id is validated against the cached session.

## Conventions when editing this repo

- Run `dart analyze` and `dart test` before claiming a task complete. Both must pass with zero issues.
- Never introduce a new public symbol without a test in `test/`.
- Use the `dart:developer` `log` (with `name: 'multipart_resumable'`) for any internal diagnostic output — never `print`.
- Pure-Dart only. No Flutter imports — the package targets servers, CLI tools, and (eventually) Flutter via platform-agnostic `dart:io`.
- Errors: extend `UploadException` (sealed); update consumer-facing `switch` examples in `README.md` and `SKILL.md` accordingly.
- See [`CHANGELOG.md`](CHANGELOG.md) for semver discipline. Public-API additions are minor bumps; behavior changes that consumers can observe are minor or major depending on impact.

## What NOT to do

- Don't add Flutter as a dependency.
- Don't change the wire format of `UploadSession.toJson` without a migration plan — it's persisted on disk by the `FileUploadSessionStore`.
- Don't attach the auth header to presigned-URL `PUT` requests. The current design isolates `putPart` / `putObject` from API auth; preserve this.
- Don't bypass the test suite to "fix" lint warnings — the lint config is strict on purpose.
