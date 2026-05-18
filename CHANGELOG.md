# Changelog

## 0.3.0

Bug-fix and ergonomics release. All public-API changes are **purely additive** — existing code compiles and runs unchanged. See **Migration** for the two minor behavior shifts to be aware of.

### Added

- **`ResumableClientConfig.authorizationHeaderProvider`** — async provider whose return value is attached as an `Authorization` header on every API call (`init`, `status`, `presign`, `complete`, `singleInit`). Never attached to the presigned-URL `PUT`, so the token can't leak to S3. The header name is configurable via `authorizationHeaderName` (default: `Authorization`).
- **`ResumableClientConfig.serverMaxUploadSizeBytes`** — replaces the previously hard-coded 2 GiB ceiling. Files larger than this fail with `FileIsTooLargeUploadException` before any network call. Defaults to 2 GiB to preserve prior behavior.

### Changed (behavior)

- **`FileUploadSessionStore.loadByPath` no longer throws on a corrupt cache file.** Instead it returns `null` and best-effort deletes the bad file, so the next call to `start()` can recover by initializing a fresh session. Previously a truncated/corrupted JSON file made every subsequent `start()` fail with a `FormatException`.
- **`existingId` is now validated against the cached session id.** If the supplied id doesn't match the session stored on disk for that file path, `start()` completes with `UnknownUploadException` instead of silently loading a different session.
- **`UploadController.cdnUrl` and `done` now defensively return `null` / `Left(UnknownUploadException)` if `_key` is missing.** Previously the URL was built as `'<cdnBaseUrl>/null'`. Reaching this state requires `complete()` to be called without `setSessionInfo()` first, which the uploader never does — but the defensive code prevents bad strings if a custom uploader misuses the controller.
- **Exceptions thrown from a user-supplied `onError` callback are now logged via `dart:developer`** (`name: 'multipart_resumable'`) instead of being silently swallowed. The upload still completes with the underlying failure as before.

### Migration

For most consumers: **no action needed**. Existing constructors, `start()` calls, and `controller.done` results are unchanged.

Two cases worth checking:

1. **If you were relying on `existingId` accepting any non-null sentinel**, you must now pass the actual session id. The simplest pattern is to capture `controller.id` after a successful `start()` (or read it from a previous run's persisted record) and pass that exact value when resuming. If you don't track the id, just omit `existingId` entirely — the uploader will load the cached session by file path and continue.

2. **If your `onError` callback used to throw exceptions silently**, those exceptions are now logged. They never propagated to consumers and still don't, but they'll show up in the developer log under the `multipart_resumable` name.

The hard-coded 2 GiB rejection that used to throw a generic `FileIsTooLargeUploadException` is now configurable via `serverMaxUploadSizeBytes`. Existing code that hits this path still gets the same exception type with the same default 2 GiB threshold.

## 0.2.0

Bug-fix release. The public API surface is unchanged — no source-level breaking changes — but two behaviors that consumers may observe were corrected. See **Migration** below.

### Fixed

- **HTTP 429 from `init` / `singleInit` is now correctly mapped to `RateLimitExceededUploadException`.** Previously these endpoints wrapped every error in a generic `StateError` before it reached the rate-limit detector, so 429s on session creation surfaced as `UnknownUploadException`.
- **Session cache key now uses the file's absolute path instead of its basename.** Two files with the same name in different directories no longer collide on disk.
- **Pause/resume race fixed.** The previous implementation could deadlock if `resume()` fired between the loop's `isPaused` check and the broadcast-stream subscription. Pause-wait is now `Completer`-based.
- **`UploadController.dispose()` no longer leaks awaiters of `done`.** If `dispose()` is called before `complete()` / `completeError()`, the `done` future now completes with `UnknownUploadException` instead of hanging forever.
- **`UploadController.cancel()` is now reliable when called before the uploader subscribes.** A persistent `_cancelRequested` flag is checked at loop entry, so a cancel issued immediately after `start()` is no longer silently dropped.
- **`UploadController.cancel()` is now idempotent.** Repeated calls emit a single event on `onCancelStream` (was: one per call).

### Internal

- Removed unused `StackTrace` parameter from internal error mapper.
- `session_store.dart` now imports domain entities directly instead of through the public barrel.
- Added strict analysis options (`package:lints/recommended` plus strict-casts, strict-inference, strict-raw-types, and ~30 additional lints).
- Added `lints` and `meta` dependencies; fixed all analyzer warnings.

### Migration

For most consumers: **no action needed**. Just bump the dependency version.

Two edge cases worth checking:

1. **In-progress uploads from a previous version cannot be resumed under 0.2.0.**
   The session cache key changed from basename to absolute file path, so the persisted session files written by 0.1.x are not findable by 0.2.0. Those files will sit orphaned in `Directory.systemTemp` (filenames `mp_*.json`); they're safe to delete. New uploads work normally. If you must preserve an in-flight upload across the upgrade, finish it on 0.1.x first.

2. **If you `switch`/`catch` on `UnknownUploadException` to handle 429s from `init` / `singleInit`, switch to `RateLimitExceededUploadException`.** Code that already handles `RateLimitExceededUploadException` benefits automatically.

### Skipped (intentional)

- Per-request `Dio()` instances in `putPart` / `putObject` were left as-is. This pattern is intentional: it isolates S3 presigned-URL traffic from the consumer's auth/log interceptors so that, e.g., an auth-header interceptor doesn't leak a Bearer token to S3.

## 0.1.0

Initial release.
