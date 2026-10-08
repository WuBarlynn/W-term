import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

import 'rust_inputs.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    output.dependencies.addAll(rustBuildInputs(input.packageRoot));
    await const FlutterRustBridgeNativeAssetsBuilder(cratePath: 'rust')
        .run(input: input, output: output);
  });
}
