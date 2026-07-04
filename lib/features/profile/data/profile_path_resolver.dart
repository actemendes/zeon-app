import 'dart:io';

import 'package:path/path.dart' as p;

class ProfilePathResolver {
  const ProfilePathResolver(this._workingDir, this._tempDir);

  final Directory _workingDir;
  final Directory _tempDir;

  Directory get directory => Directory(p.join(_workingDir.path, "configs"));

  Directory get tempDirectory => Directory(p.join(_tempDir.path, "zeon-profile-configs"));

  File file(String fileName) {
    return encryptedFile(fileName);
  }

  File encryptedFile(String fileName) {
    return File(p.join(directory.path, "$fileName.zcfg"));
  }

  File legacyPlaintextFile(String fileName) {
    return File(p.join(directory.path, "$fileName.json"));
  }

  File tempFile(String fileName) {
    final opaqueName = fileName.hashCode.toUnsigned(32).toRadixString(16).padLeft(8, '0');
    return File(p.join(tempDirectory.path, "$opaqueName.tmp.json"));
  }

  File legacyTempFile(String fileName) => File(p.join(tempDirectory.path, "$fileName.tmp.json"));
}
