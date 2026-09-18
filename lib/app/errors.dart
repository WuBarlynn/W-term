/// User-facing errors omit Rust backtraces and implementation details.
String userFacingError(Object error) {
  var text = error.toString().split('\n\nStack backtrace:').first;
  if (text.startsWith('AnyhowException(')) {
    text = text.substring('AnyhowException('.length);
    if (text.endsWith(')')) text = text.substring(0, text.length - 1);
  }
  if (text.contains('Connection refused')) return '服务器拒绝连接，请检查地址、端口和 SSH 服务。';
  if (text.contains('timed out')) return '连接超时，请检查网络与服务器状态。';
  if (text.contains('Authentication rejected')) return '认证失败，请检查用户名和凭证。';
  if (text.contains('Destination already exists')) return '目标文件已存在，请使用其他名称。';
  if (text.contains('Session is disconnected')) return '会话已断开，请重新连接。';
  if (text.contains('Cannot decrypt or parse private key')) {
    return '无法读取私钥，请检查文件格式和口令。';
  }
  return text.length > 400 ? '${text.substring(0, 400)}…' : text;
}
