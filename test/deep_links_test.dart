import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/deep_links.dart';

void main() {
  test('deep links build a quick-connect profile without credentials', () {
    final profile = hostProfileFromDeepLink(
      Uri.parse(
        'wterm://connect?host=example.com&port=2222&username=deploy&name=Prod',
      ),
    );
    expect(profile?.host, 'example.com');
    expect(profile?.port, 2222);
    expect(profile?.username, 'deploy');
    expect(profile?.name, 'Prod');
  });

  test('invalid deep links are rejected', () {
    expect(hostProfileFromDeepLink(Uri.parse('https://example.com')), isNull);
    expect(hostProfileFromDeepLink(Uri.parse('wterm://other?host=a')), isNull);
    expect(hostProfileFromDeepLink(Uri.parse('wterm://connect')), isNull);
    expect(
      hostProfileFromDeepLink(Uri.parse('wterm://connect?host=a&port=0')),
      isNull,
    );
    expect(
      hostProfileFromDeepLink(
        Uri.parse('wterm://connect?host=a%20b&username=root'),
      ),
      isNull,
    );
  });

  test('credentials in a deep link are ignored', () {
    final profile = hostProfileFromDeepLink(
      Uri.parse(
        'wterm://connect?host=example.com&username=root&password=secret',
      ),
    );
    expect(profile, isNotNull);
    expect(profile!.identityId, isEmpty);
  });
}
