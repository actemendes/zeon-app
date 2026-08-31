import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zeon/features/log/data/log_path_resolver.dart';

void main() {
  test('resolves current core and network-extension diagnostic logs', () {
    final resolver = LogPathResolver(Directory(p.join('root', 'Working')));

    expect(resolver.coreRuntimeFile().path, p.join('root', 'Working', 'data', 'box.log'));
    expect(resolver.coreStderrFile(3).path, p.join('root', 'Working', 'data', 'stderr3.log'));
    expect(resolver.coreStderrFile().path, p.join('root', 'Working', 'data', 'stderr4.log'));
    expect(
      resolver.coreStderrFiles().map((file) => file.path),
      containsAll([
        p.join('root', 'Working', 'data', 'stderr3.log'),
        p.join('root', 'Working', 'data', 'stderr4.log'),
        p.join('root', 'Working', 'data', 'stderr3.log.old'),
        p.join('root', 'Working', 'data', 'stderr4.log.old'),
        p.join('root', 'Working', 'data', 'stderr.log'),
        p.join('root', 'Working', 'stderr.log'),
      ]),
    );
    expect(resolver.networkExtensionErrorFile().path, p.join('root', 'Working', 'network_extension_error.log'));
    expect(
      resolver.previousNetworkExtensionErrorFile().path,
      p.join('root', 'Working', 'network_extension_error.previous.log'),
    );
  });
}
