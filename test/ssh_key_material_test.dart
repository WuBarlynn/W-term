import 'package:flutter_test/flutter_test.dart';
import 'package:wterm/app/ssh_key_material.dart';

void main() {
  const key =
      '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----';
  const cert =
      '-----BEGIN OPENSSH CERTIFICATE-----\nxyz\n-----END OPENSSH CERTIFICATE-----';

  test('certificate validation accepts OpenSSH PEM blocks', () {
    expect(sshCertificateError(cert), isNull);
    expect(sshCertificateError(''), isNull);
    expect(sshCertificateError('not a certificate'), isNotNull);
    expect(
      sshCertificateError('-----BEGIN OPENSSH CERTIFICATE-----\nmissing end'),
      isNotNull,
    );
    expect(sshCertificateError('x' * 32769), isNotNull);
  });

  test('certificate is appended once and kept with the private key', () {
    final combined = keyWithSshCertificate(key, cert);
    expect(combined, contains(key));
    expect(combined, contains(cert));
    expect(keyWithSshCertificate(combined, cert), combined);
    expect(keyWithSshCertificate(key, ''), key.trim());
  });
}
