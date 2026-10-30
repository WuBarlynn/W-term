const sshCertificateBegin = '-----BEGIN OPENSSH CERTIFICATE-----';
const sshCertificateEnd = '-----END OPENSSH CERTIFICATE-----';

/// Validates an OpenSSH user certificate before it is appended to a key.
String? sshCertificateError(String certificate) {
  final value = certificate.trim();
  if (value.isEmpty) return null;
  if (value.length > 32768) return 'SSH 证书不能超过 32 KiB';
  if (value.contains('\x00')) return 'SSH 证书包含无效字符';
  if (!value.startsWith(sshCertificateBegin) ||
      !value.contains(sshCertificateEnd)) {
    return '不是有效的 OpenSSH 证书';
  }
  return null;
}

/// Stores the certificate after the private key in the encrypted key field.
String keyWithSshCertificate(String key, String certificate) {
  final privateKey = key.trim();
  final cert = certificate.trim();
  if (cert.isEmpty || privateKey.contains(sshCertificateBegin)) {
    return privateKey;
  }
  return '$privateKey\n$cert';
}
