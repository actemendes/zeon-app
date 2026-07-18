import 'dart:io';

import 'package:path/path.dart' as p;

/// Moves legacy Android working files out of app-specific external storage.
///
/// External storage is readable over ADB on a number of Android versions and
/// devices. The destination must be an app-private internal directory.
abstract final class AndroidWorkingDirectoryMigration {
  static const _completionMarkerName = '.zeon-external-migration-complete';

  static Future<bool> migrate({required Directory source, required Directory destination}) async {
    if (_samePath(source.path, destination.path) || !await source.exists()) {
      return true;
    }

    final completionMarker = File(p.join(destination.path, _completionMarkerName));
    try {
      await destination.create(recursive: true);
      if (!await completionMarker.exists()) {
        // Copy the complete tree before touching the source. If disk I/O fails,
        // the app can keep using the intact legacy directory and retry later.
        await _copyDirectoryContents(source, destination);
        await completionMarker.writeAsString('complete', flush: true);
      }

      // Cleanup is best effort. A completed private copy is authoritative; an
      // undeleted external copy is retried on the next launch without
      // overwriting newer private data.
      try {
        await source.delete(recursive: true);
      } catch (_) {}
      return true;
    } catch (_) {
      try {
        if (await completionMarker.exists()) await completionMarker.delete();
      } catch (_) {}
      // Keep using the legacy directory when migration cannot be completed so
      // an update cannot silently strand an existing profile or core database.
      return false;
    }
  }

  static Future<void> _copyDirectoryContents(Directory source, Directory destination) async {
    await for (final entity in source.list(followLinks: false)) {
      final relativePath = p.relative(entity.path, from: source.path);
      if (relativePath == '..' || p.isAbsolute(relativePath) || relativePath.startsWith('..${p.separator}')) {
        throw const FileSystemException('Unsafe migration path');
      }

      final targetPath = p.join(destination.path, relativePath);
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      switch (type) {
        case FileSystemEntityType.directory:
          final targetDirectory = Directory(targetPath);
          await targetDirectory.create(recursive: true);
          await _copyDirectoryContents(Directory(entity.path), targetDirectory);
        case FileSystemEntityType.file:
          await _copyVerified(File(entity.path), File(targetPath));
        case FileSystemEntityType.link:
          // Never follow or copy a link planted in an externally writable area.
          break;
        case FileSystemEntityType.notFound:
          break;
        default:
          throw const FileSystemException('Unsupported migration entry');
      }
    }
  }

  static Future<void> _copyVerified(File source, File destination) async {
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.zeon-migration');

    try {
      if (await temporary.exists()) await temporary.delete();
      await source.copy(temporary.path);
      if (await source.length() != await temporary.length()) {
        throw const FileSystemException('Incomplete working directory migration');
      }

      if (await destination.exists()) await destination.delete();
      await temporary.rename(destination.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  static bool _samePath(String first, String second) {
    return p.equals(p.normalize(p.absolute(first)), p.normalize(p.absolute(second)));
  }
}
