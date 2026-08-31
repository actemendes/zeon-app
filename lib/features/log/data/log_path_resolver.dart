import 'dart:io';

import 'package:path/path.dart' as p;

class LogPathResolver {
  const LogPathResolver(this._workingDir);

  final Directory _workingDir;

  Directory get directory => _workingDir;

  File coreFile() {
    return File(p.join(directory.path, "box.log"));
  }

  /// File produced by the current hcore runtime.
  File coreRuntimeFile() {
    return File(p.join(directory.path, "data", "box.log"));
  }

  File coreStderrFile([int mode = 4]) {
    return File(p.join(directory.path, "data", "stderr$mode.log"));
  }

  /// Known stderr/crash-output locations, ordered from legacy to current.
  ///
  /// hcore uses mode 3 for the normal insecure service and mode 4 for the
  /// background insecure service. `RedirectStderr` rotates the current file to
  /// `.old`, so both files are useful after a native crash or provider restart.
  List<File> coreStderrFiles() {
    return [
      File(p.join(directory.path, "stderr.log.old")),
      File(p.join(directory.path, "stderr.log")),
      File(p.join(directory.path, "stderr3.log.old")),
      File(p.join(directory.path, "stderr3.log")),
      File(p.join(directory.path, "stderr4.log.old")),
      File(p.join(directory.path, "stderr4.log")),
      File(p.join(directory.path, "data", "stderr.log.old")),
      File(p.join(directory.path, "data", "stderr.log")),
      File(p.join(directory.path, "data", "stderr3.log.old")),
      File(p.join(directory.path, "data", "stderr4.log.old")),
      coreStderrFile(3),
      coreStderrFile(),
    ];
  }

  File networkExtensionErrorFile() {
    return File(p.join(directory.path, "network_extension_error.log"));
  }

  File previousNetworkExtensionErrorFile() {
    return File(p.join(directory.path, "network_extension_error.previous.log"));
  }

  File appFile() {
    return File(p.join(directory.path, "app.log"));
  }
}
