import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Saves the screenshots taken by screenshots_test.dart into the package's
/// screenshots folder (shown on pub.dev and in the README).
Future<void> main() => integrationDriver(
      onScreenshot: (name, bytes, [args]) async {
        final file = File('../screenshots/$name.png');
        await file.create(recursive: true);
        await file.writeAsBytes(bytes);
        return true;
      },
    );
