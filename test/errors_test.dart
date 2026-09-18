import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/errors.dart';

void main() {
  test('Rust stack traces never enter the user-facing error', () {
    final message = userFacingError(
      'AnyhowException(Connection refused (os error 61)\n\nStack backtrace:\nsecret diagnostic path)',
    );
    expect(message, contains('服务器拒绝连接'));
    expect(message, isNot(contains('Stack backtrace')));
    expect(message, isNot(contains('diagnostic')));
  });
  test('unknown errors are bounded', () {
    expect(userFacingError('x' * 1000).length, lessThanOrEqualTo(401));
  });
}
