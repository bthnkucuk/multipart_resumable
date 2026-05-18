import 'package:multipart_resumable/multipart_resumable.dart';
import 'package:test/test.dart';

void main() {
  test('RetryPolicy delay grows exponentially', () {
    const policy = RetryPolicy(maxRetries: 3, baseDelay: Duration(milliseconds: 500));
    expect(policy.delayForAttempt(0), const Duration(milliseconds: 500));
    expect(policy.delayForAttempt(1), const Duration(milliseconds: 1000));
    expect(policy.delayForAttempt(2), const Duration(milliseconds: 2000));
  });
}
