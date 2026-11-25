import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyu_playback_probe/client_private_storage.dart';

void main() {
  test(
    'Android cache locator retains the native fixed staging suffix',
    () async {
      final base = await Directory.systemTemp.createTemp('shiyu-cache-value-');
      final cache = Directory('${base.path}/synthetic-cache');
      try {
        final location = AndroidMaterialImportCache(cacheDirectory: cache);
        expect(
          location.stagingRoot.absolute.path,
          Directory('${cache.absolute.path}/material_import_v1').path,
        );
        expect(await cache.exists(), isFalse);
        expect(await base.list().toList(), isEmpty);
      } finally {
        await base
            .delete(); // Non-recursive: unexpected contents are preserved.
      }
    },
  );

  test(
    'non-Android cache injection fails before creating a profile or lock',
    () async {
      if (Platform.isAndroid) return;
      final base = await Directory.systemTemp.createTemp(
        'shiyu-cache-contract-',
      );
      final root = Directory('${base.path}/profile');
      try {
        await expectLater(
          ClientPrivateStorage.open(
            root: root,
            proxyCommand: const ['unused-proxy.exe'],
            androidImportCache: AndroidMaterialImportCache(
              cacheDirectory: base,
            ),
          ),
          throwsArgumentError,
        );
        expect(await root.exists(), isFalse);
        expect(await base.list().toList(), isEmpty);
      } finally {
        await base.delete(); // Non-recursive: do not erase a failed fixture.
      }
    },
  );
}
