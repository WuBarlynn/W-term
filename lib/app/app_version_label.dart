import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Read the installed bundle, rather than a hard-coded source version, so users
/// can distinguish a stale IPA from the app which was actually rebuilt.
class AppVersionLabel extends StatefulWidget {
  const AppVersionLabel({super.key});
  @override
  State<AppVersionLabel> createState() => _AppVersionLabelState();
}

class _AppVersionLabelState extends State<AppVersionLabel> {
  late final Future<String?> version = readVersion();
  Future<String?> readVersion() async {
    try {
      return await const MethodChannel('dev.wterm/biometrics')
          .invokeMethod<String>('buildVersion');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: version,
    builder: (_, snapshot) => snapshot.data == null
        ? const SizedBox.shrink()
        : Text(
            'W Term ${snapshot.data}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
  );
}
