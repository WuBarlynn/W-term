import 'dart:io';

import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

import 'rust_inputs.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    output.dependencies.addAll(rustBuildInputs(input.packageRoot));
    final opensslDir =
        Platform.environment['OPENSSL_DIR'] ??
        (Platform.isWindows ? r'C:\Program Files\OpenSSL' : null);
    final opensslLib =
        Platform.environment['OPENSSL_LIB_DIR'] ??
        (Platform.isWindows ? r'C:\Program Files\OpenSSL\lib\VC\x64\MD' : null);
    final opensslInclude =
        Platform.environment['OPENSSL_INCLUDE_DIR'] ??
        (Platform.isWindows ? r'C:\Program Files\OpenSSL\include' : null);
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: {
        'OPENSSL_DIR': ?opensslDir,
        'OPENSSL_LIB_DIR': ?opensslLib,
        'OPENSSL_INCLUDE_DIR': ?opensslInclude,
      },
    ).run(input: input, output: output);
  });
}
