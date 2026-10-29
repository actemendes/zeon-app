import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:installed_apps/app_info.dart';
import 'package:zeon/features/per_app_proxy/data/windows_icon_extractor.dart';

typedef RegistryOutputReader = Future<String> Function(List<String> arguments);
typedef RunningProcessPathsReader = Future<List<String>> Function();

@immutable
class DiscoveredWindowsProgram {
  const DiscoveredWindowsProgram({
    required this.name,
    required this.executablePath,
    required this.isSystemApp,
    this.versionName = '',
    this.iconSource,
    this.icon,
  });

  final String name;
  final String executablePath;
  final bool isSystemApp;
  final String versionName;
  final String? iconSource;
  final Uint8List? icon;

  String get executableName => executablePath.split(RegExp(r'[\\/]')).last;

  DiscoveredWindowsProgram copyWith({
    String? name,
    String? executablePath,
    bool? isSystemApp,
    String? versionName,
    String? iconSource,
    Uint8List? icon,
  }) {
    return DiscoveredWindowsProgram(
      name: name ?? this.name,
      executablePath: executablePath ?? this.executablePath,
      isSystemApp: isSystemApp ?? this.isSystemApp,
      versionName: versionName ?? this.versionName,
      iconSource: iconSource ?? this.iconSource,
      icon: icon ?? this.icon,
    );
  }

  AppInfo toAppInfo() => AppInfo(
    name: name,
    icon: icon,
    packageName: executablePath,
    versionName: versionName.isNotEmpty ? versionName : executableName,
    versionCode: 1,
    builtWith: BuiltWith.native_or_others,
    installedTimestamp: 0,
  );
}

class WindowsInstalledAppsService {
  WindowsInstalledAppsService({
    RegistryOutputReader? registryReader,
    RunningProcessPathsReader? runningProcessPathsReader,
    Map<String, String>? environment,
    bool Function(String path)? fileExists,
    List<String> Function(String directoryPath, {int maxDepth})? exeFinder,
    WindowsIconLoader? iconLoader,
  }) : _registryReader = registryReader ?? _defaultRegistryReader,
       _runningProcessPathsReader = runningProcessPathsReader ?? _defaultRunningProcessPathsReader,
       _environment = environment ?? Platform.environment,
       _fileExists = fileExists ?? ((path) => File(path).existsSync()),
       _exeFinder = exeFinder ?? _defaultExeFinder,
       _iconLoader = iconLoader ?? WindowsIconExtractor.extractIconPng;

  final RegistryOutputReader _registryReader;
  final RunningProcessPathsReader _runningProcessPathsReader;
  final Map<String, String> _environment;
  final bool Function(String path) _fileExists;
  final List<String> Function(String directoryPath, {int maxDepth}) _exeFinder;
  final WindowsIconLoader _iconLoader;

  static Uint8List? extractExecutableIcon(String executableOrIconPath) =>
      WindowsIconExtractor.extractIconPng(executableOrIconPath);

  static const List<String> _uninstallRegistryKeys = <String>[
    r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
  ];

  static const List<String> _appPathsRegistryKeys = <String>[
    r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
    r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
  ];

  static const Set<String> _selfExecutables = <String>{
    'zeon.exe',
    'zeoncli.exe',
    'hiddify.exe',
    'hiddifycli.exe',
    'hiddifynext.exe',
  };

  static final RegExp _ignoredExecutablePattern = RegExp(
    r'^(unins\d*|uninstall.*|uninst.*|setup.*|install.*|update|updater.*|.*updater|crashpad_handler|crashreporter.*|.*crashhandler.*|vc_redist.*|vcredist.*|dxsetup|dotnet.*|elevate|squirrel|createdump|unitycrashhandler\d*|cefsharp\.browsersubprocess|QtWebEngineProcess)\.exe$',
    caseSensitive: false,
  );

  static const Map<String, String> _knownExecutableTitles = <String, String>{
    'chrome.exe': 'Google Chrome',
    'msedge.exe': 'Microsoft Edge',
    'firefox.exe': 'Mozilla Firefox',
    'brave.exe': 'Brave Browser',
    'opera.exe': 'Opera',
    'vivaldi.exe': 'Vivaldi',
    'telegram.exe': 'Telegram Desktop',
    'ayugram.exe': 'AyuGram Desktop',
    'discord.exe': 'Discord',
    'discordptb.exe': 'Discord PTB',
    'discordcanary.exe': 'Discord Canary',
    'steam.exe': 'Steam',
    'epicgameslauncher.exe': 'Epic Games Launcher',
    'battle.net.exe': 'Battle.net',
    'riotclientservices.exe': 'Riot Client',
    'eadestkop.exe': 'EA App',
    'eadesktop.exe': 'EA App',
    'upc.exe': 'Ubisoft Connect',
    'spotify.exe': 'Spotify',
    'code.exe': 'Visual Studio Code',
    'devenv.exe': 'Visual Studio',
    'idea64.exe': 'IntelliJ IDEA',
    'pycharm64.exe': 'PyCharm',
    'webstorm64.exe': 'WebStorm',
    'goland64.exe': 'GoLand',
    'studio64.exe': 'Android Studio',
    'cursor.exe': 'Cursor',
    'windsurf.exe': 'Windsurf',
    'obsidian.exe': 'Obsidian',
    'notion.exe': 'Notion',
    'slack.exe': 'Slack',
    'zoom.exe': 'Zoom',
    'skype.exe': 'Skype',
    'whatsapp.exe': 'WhatsApp',
    'viber.exe': 'Viber',
    'obs64.exe': 'OBS Studio',
    'vlc.exe': 'VLC media player',
    'mpc-hc64.exe': 'Media Player Classic',
    'potplayermini64.exe': 'PotPlayer',
    'qbittorrent.exe': 'qBittorrent',
    'utorrent.exe': 'uTorrent',
    'bittorrent.exe': 'BitTorrent',
    'transmission-qt.exe': 'Transmission',
    'postman.exe': 'Postman',
    'insomnia.exe': 'Insomnia',
    'docker desktop.exe': 'Docker Desktop',
    'filezilla.exe': 'FileZilla',
    'putty.exe': 'PuTTY',
    'winscp.exe': 'WinSCP',
    '7zfm.exe': '7-Zip',
    'winrar.exe': 'WinRAR',
    'notepad++.exe': 'Notepad++',
    'blender.exe': 'Blender',
    'javaw.exe': 'Java (Minecraft / JVM)',
  };

  Future<List<AppInfo>> getInstalledApps({
    bool hideSystem = true,
    Iterable<String> customPaths = const <String>[],
  }) async {
    final programs = await discoverPrograms(
      hideSystem: hideSystem,
      customPaths: customPaths,
    );
    return programs.map((program) => program.toAppInfo()).toList(growable: false);
  }

  Future<List<DiscoveredWindowsProgram>> discoverPrograms({
    bool hideSystem = true,
    Iterable<String> customPaths = const <String>[],
  }) async {
    final byPath = <String, DiscoveredWindowsProgram>{};
    final customNormalizedSet = <String>{};

    // 1. Always include explicit custom / already-selected executable paths first.
    for (final rawPath in customPaths) {
      final cleaned = normalizeExecutablePath(rawPath);
      if (cleaned == null) continue;
      final key = cleaned.toLowerCase();
      customNormalizedSet.add(key);
      byPath[key] = DiscoveredWindowsProgram(
        name: friendlyProgramName(cleaned),
        executablePath: cleaned,
        isSystemApp: false,
      );
    }

    // 2. Query Windows Uninstall registry keys.
    for (final regKey in _uninstallRegistryKeys) {
      try {
        final output = await _registryReader(<String>['query', regKey, '/s']);
        for (final entry in parseUninstallRegistryOutput(output)) {
          _mergeCandidate(byPath, entry);
        }
      } catch (_) {
        // Ignore individual registry hive errors.
      }
    }

    // 3. Query Windows App Paths registry keys.
    for (final regKey in _appPathsRegistryKeys) {
      try {
        final output = await _registryReader(<String>['query', regKey, '/s']);
        for (final entry in parseAppPathsRegistryOutput(output)) {
          _mergeCandidate(byPath, entry);
        }
      } catch (_) {
        // Ignore individual registry hive errors.
      }
    }

    // 4. Scan standard program installation directories.
    for (final dirPath in _candidateInstallRootDirectories()) {
      for (final program in _scanInstallRootDirectory(dirPath)) {
        _mergeCandidate(byPath, program);
      }
    }

    // 5. Discover currently running processes with full executable paths.
    try {
      final runningPaths = await _runningProcessPathsReader();
      for (final rawPath in runningPaths) {
        final cleaned = normalizeExecutablePath(rawPath);
        if (cleaned == null || !_fileExists(cleaned)) continue;
        if (isIgnoredExecutable(cleaned)) continue;
        _mergeCandidate(
          byPath,
          DiscoveredWindowsProgram(
            name: friendlyProgramName(cleaned),
            executablePath: cleaned,
            isSystemApp: isSystemExecutablePath(cleaned),
          ),
        );
      }
    } catch (_) {
      // Ignore process listing errors.
    }

    final filtered = byPath.entries
        .where((entry) {
          if (customNormalizedSet.contains(entry.key)) return true;
          if (hideSystem && entry.value.isSystemApp) return false;
          return true;
        })
        .map((entry) => _attachProgramIcon(entry.value))
        .toList();

    filtered.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (byName != 0) return byName;
      return a.executablePath.toLowerCase().compareTo(b.executablePath.toLowerCase());
    });

    return filtered;
  }

  DiscoveredWindowsProgram _attachProgramIcon(DiscoveredWindowsProgram program) {
    if (program.icon != null) return program;
    Uint8List? iconBytes;
    final source = program.iconSource?.trim();
    if (source != null && source.isNotEmpty) {
      iconBytes = _iconLoader(source);
    }
    iconBytes ??= _iconLoader(program.executablePath);
    if (iconBytes == null) return program;
    return program.copyWith(icon: iconBytes);
  }

  void _mergeCandidate(
    Map<String, DiscoveredWindowsProgram> byPath,
    DiscoveredWindowsProgram candidate,
  ) {
    final cleaned = normalizeExecutablePath(candidate.executablePath);
    if (cleaned == null) return;
    if (isIgnoredExecutable(cleaned)) return;
    final key = cleaned.toLowerCase();
    final existing = byPath[key];
    if (existing == null) {
      byPath[key] = DiscoveredWindowsProgram(
        name: candidate.name.trim().isNotEmpty ? candidate.name.trim() : friendlyProgramName(cleaned),
        executablePath: cleaned,
        isSystemApp: candidate.isSystemApp,
        versionName: candidate.versionName,
        iconSource: candidate.iconSource,
        icon: candidate.icon,
      );
      return;
    }
    // Prefer richer display name from Registry over generic filename.
    final genericExisting = existing.name.toLowerCase() == existing.executableName.replaceAll('.exe', '').toLowerCase();
    final betterName = genericExisting && candidate.name.trim().isNotEmpty ? candidate.name.trim() : existing.name;
    byPath[key] = DiscoveredWindowsProgram(
      name: betterName,
      executablePath: existing.executablePath,
      isSystemApp: existing.isSystemApp && candidate.isSystemApp,
      versionName: existing.versionName.isNotEmpty ? existing.versionName : candidate.versionName,
      iconSource: existing.iconSource ?? candidate.iconSource,
      icon: existing.icon ?? candidate.icon,
    );
  }

  @visibleForTesting
  List<DiscoveredWindowsProgram> parseUninstallRegistryOutput(String output) {
    final results = <DiscoveredWindowsProgram>[];
    String? displayName;
    String? displayIcon;
    String? installLocation;
    String? displayVersion;
    var systemComponent = false;

    void flushCurrent() {
      final name = displayName?.trim();
      if (name != null && name.isNotEmpty) {
        final exePath = _resolveRegistryExecutablePath(
          displayIcon: displayIcon,
          installLocation: installLocation,
          displayName: name,
        );
        if (exePath != null && !isIgnoredExecutable(exePath)) {
          final isSys = systemComponent || isSystemExecutablePath(exePath) || _isSystemDisplayName(name);
          final resolvedIconSource = _resolveRegistryIconSource(displayIcon: displayIcon, fallbackExePath: exePath);
          results.add(
            DiscoveredWindowsProgram(
              name: name,
              executablePath: exePath,
              isSystemApp: isSys,
              versionName: displayVersion?.trim() ?? '',
              iconSource: resolvedIconSource,
            ),
          );
        }
      }
      displayName = null;
      displayIcon = null;
      installLocation = null;
      displayVersion = null;
      systemComponent = false;
    }

    for (final rawLine in output.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;
      if (line.startsWith('HKEY_')) {
        flushCurrent();
        continue;
      }
      final match = RegExp(r'^\s+([^\s]+)\s+REG_[A-Z0-9_]+\s+(.*)$').firstMatch(line);
      if (match == null) continue;
      final valueName = match.group(1)!.trim().toLowerCase();
      final valueData = match.group(2)!.trim();
      if (valueData.isEmpty) continue;

      switch (valueName) {
        case 'displayname':
          displayName = valueData;
        case 'displayicon':
          displayIcon = valueData;
        case 'installlocation':
          installLocation = valueData;
        case 'displayversion':
          displayVersion = valueData;
        case 'systemcomponent':
          systemComponent = valueData == '0x1' || valueData == '1';
      }
    }
    flushCurrent();
    return results;
  }

  String? _resolveRegistryIconSource({required String? displayIcon, required String fallbackExePath}) {
    if (displayIcon == null || displayIcon.trim().isEmpty) return fallbackExePath;
    final parsed = WindowsIconExtractor.parseIconLocation(displayIcon);
    if (parsed == null) return fallbackExePath;
    if (_fileExists(parsed.filePath)) {
      return displayIcon.trim();
    }
    return fallbackExePath;
  }

  @visibleForTesting
  List<DiscoveredWindowsProgram> parseAppPathsRegistryOutput(String output) {
    final results = <DiscoveredWindowsProgram>[];
    for (final rawLine in output.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trimRight();
      final match = RegExp(r'^\s+\(.+\)\s+REG_SZ\s+(.*)$').firstMatch(line);
      if (match == null) continue;
      final rawPath = extractExecutablePathFromCommand(match.group(1)!);
      if (rawPath == null || !_fileExists(rawPath) || isIgnoredExecutable(rawPath)) continue;
      results.add(
        DiscoveredWindowsProgram(
          name: friendlyProgramName(rawPath),
          executablePath: rawPath,
          isSystemApp: isSystemExecutablePath(rawPath),
        ),
      );
    }
    return results;
  }

  String? _resolveRegistryExecutablePath({
    required String? displayIcon,
    required String? installLocation,
    required String displayName,
  }) {
    if (displayIcon != null && displayIcon.trim().isNotEmpty) {
      final iconExe = extractExecutablePathFromCommand(displayIcon);
      if (iconExe != null && !isIgnoredExecutable(iconExe) && _fileExists(iconExe)) {
        return iconExe;
      }
    }
    if (installLocation != null && installLocation.trim().isNotEmpty) {
      final dirPath = _stripQuotes(installLocation.trim());
      if (dirPath.isNotEmpty) {
        final candidates = _exeFinder(dirPath, maxDepth: 2)
            .where((path) => !isIgnoredExecutable(path))
            .toList(growable: false);
        if (candidates.isNotEmpty) {
          return _pickBestExecutableInFolder(candidates, preferredTitle: displayName);
        }
      }
    }
    return null;
  }

  List<String> _candidateInstallRootDirectories() {
    final roots = <String>[];
    void addIfNotEmpty(String? path) {
      if (path == null || path.trim().isEmpty) return;
      final normalized = path.trim().replaceAll('/', r'\');
      if (!roots.any((existing) => existing.toLowerCase() == normalized.toLowerCase())) {
        roots.add(normalized);
      }
    }

    addIfNotEmpty(_environment['ProgramFiles']);
    addIfNotEmpty(_environment['ProgramFiles(x86)']);
    final localAppData = _environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.trim().isNotEmpty) {
      addIfNotEmpty('$localAppData\\Programs');
      addIfNotEmpty(localAppData);
    }
    final appData = _environment['APPDATA'];
    if (appData != null && appData.trim().isNotEmpty) {
      addIfNotEmpty(appData);
    }
    return roots;
  }

  static const Set<String> _skipTopLevelAppDataFolders = <String>{
    'temp',
    'microsoft',
    'packages',
    'connecteddevicesplatform',
    'd3dscache',
    'fontcache',
    'google\\chrome\\user data',
    'cache',
    'caches',
    'crashdumps',
    'squirreltemp',
    'nuget',
    'npm-cache',
    'pip',
    'pub',
  };

  List<DiscoveredWindowsProgram> _scanInstallRootDirectory(String rootPath) {
    final results = <DiscoveredWindowsProgram>[];
    final rootDir = Directory(rootPath);
    if (!rootDir.existsSync()) return results;

    final lowerRoot = rootPath.toLowerCase();
    final isRawAppDataRoot =
        (lowerRoot.endsWith(r'\appdata\local') || lowerRoot.endsWith(r'\appdata\roaming')) &&
        !lowerRoot.endsWith(r'\appdata\local\programs');

    List<FileSystemEntity> children;
    try {
      children = rootDir.listSync(followLinks: false);
    } catch (_) {
      return results;
    }

    for (final entity in children) {
      if (entity is! Directory) continue;
      final folderName = entity.path.split(RegExp(r'[\\/]')).last;
      if (folderName.startsWith('.')) continue;
      if (_skipTopLevelAppDataFolders.contains(folderName.toLowerCase())) continue;

      final candidates = _exeFinder(entity.path, maxDepth: isRawAppDataRoot ? 2 : 2)
          .where((path) => !isIgnoredExecutable(path))
          .toList(growable: false);
      if (candidates.isEmpty) continue;

      final bestExe = _pickBestExecutableInFolder(candidates, preferredTitle: folderName);
      if (bestExe == null) continue;

      String? folderIcon;
      final appIco = '${entity.path}\\app.ico';
      if (_fileExists(appIco)) {
        folderIcon = appIco;
      }

      results.add(
        DiscoveredWindowsProgram(
          name: friendlyProgramName(bestExe, fallbackFolderName: folderName),
          executablePath: bestExe,
          isSystemApp: isSystemExecutablePath(bestExe),
          iconSource: folderIcon,
        ),
      );
    }
    return results;
  }

  String? _pickBestExecutableInFolder(List<String> candidates, {required String preferredTitle}) {
    if (candidates.isEmpty) return null;
    final cleanPreferred = preferredTitle.toLowerCase().replaceAll(RegExp('[^a-z0-9а-яё]'), '');

    int scoreCandidate(String path) {
      final base = path.split(RegExp(r'[\\/]')).last.toLowerCase();
      final stem = base.endsWith('.exe') ? base.substring(0, base.length - 4) : base;
      final cleanStem = stem.replaceAll(RegExp('[^a-z0-9а-яё]'), '');
      var score = 0;
      if (_knownExecutableTitles.containsKey(base)) score += 100;
      if (cleanPreferred.isNotEmpty && cleanStem == cleanPreferred) score += 80;
      if (cleanPreferred.isNotEmpty && cleanPreferred.contains(cleanStem) && cleanStem.length >= 3) score += 40;
      if (cleanPreferred.isNotEmpty && cleanStem.contains(cleanPreferred) && cleanPreferred.length >= 3) score += 35;
      if (path.toLowerCase().contains(r'\application\')) score += 20;
      if (path.toLowerCase().contains(r'\bin\')) score += 10;
      // Prefer shallower executables unless inside Squirrel `app-*` folder.
      return score - path.split(RegExp(r'[\\/]')).length;
    }

    final sorted = [...candidates]..sort((a, b) => scoreCandidate(b).compareTo(scoreCandidate(a)));
    return sorted.first;
  }

  static String? extractExecutablePathFromCommand(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // Strip icon index suffix such as `,0` or `,-101`
    trimmed = trimmed.replaceFirst(RegExp(r',\s*-?\d+\s*$'), '').trim();
    if (trimmed.startsWith('"')) {
      final endQuote = trimmed.indexOf('"', 1);
      if (endQuote > 1) {
        trimmed = trimmed.substring(1, endQuote).trim();
      } else {
        trimmed = _stripQuotes(trimmed);
      }
    } else {
      final exeMatch = RegExp(r'^([a-zA-Z]:\\[^"]*?\.exe)\b', caseSensitive: false).firstMatch(trimmed);
      if (exeMatch != null) {
        trimmed = exeMatch.group(1)!.trim();
      }
    }
    return normalizeExecutablePath(trimmed);
  }

  static String? normalizeExecutablePath(String raw) {
    final stripped = _stripQuotes(raw.trim());
    if (stripped.isEmpty) return null;
    final normalized = stripped.replaceAll('/', r'\');
    if (!normalized.toLowerCase().endsWith('.exe')) return null;
    return normalized;
  }

  static bool isIgnoredExecutable(String executablePath) {
    final base = executablePath.split(RegExp(r'[\\/]')).last.toLowerCase();
    if (_selfExecutables.contains(base)) return true;
    return _ignoredExecutablePattern.hasMatch(base);
  }

  static bool isSystemExecutablePath(String executablePath) {
    final lower = executablePath.replaceAll('/', r'\').toLowerCase();
    if (lower.startsWith(r'c:\windows\') ||
        lower.contains(r'\windows\system32\') ||
        lower.contains(r'\windows\syswow64\') ||
        lower.contains(r'\windowsapps\') ||
        lower.contains(r'\microsoft shared\') ||
        lower.contains(r'\windows defender\') ||
        lower.contains(r'\windows security\') ||
        lower.contains(r'\windows nt\') ||
        lower.contains(r'\windows mail\') ||
        lower.contains(r'\windows media player\') ||
        lower.contains(r'\windows photo viewer\') ||
        lower.contains(r'\windows portable devices\') ||
        lower.contains(r'\internet explorer\') ||
        lower.contains(r'\microsoft\edgeupdate\')) {
      return true;
    }
    return false;
  }

  static bool _isSystemDisplayName(String displayName) {
    final lower = displayName.toLowerCase();
    return lower.startsWith('microsoft visual c++') ||
        lower.startsWith('microsoft .net') ||
        lower.startsWith('microsoft asp.net') ||
        lower.startsWith('microsoft windows desktop runtime') ||
        lower.startsWith('microsoft edge webview2') ||
        lower.startsWith('windows software development kit') ||
        lower.contains('redistributable');
  }

  static String friendlyProgramName(String executablePath, {String? fallbackFolderName}) {
    final parts = executablePath.replaceAll('/', r'\').split(r'\').where((p) => p.isNotEmpty).toList();
    final base = parts.isNotEmpty ? parts.last : executablePath;
    final lowerBase = base.toLowerCase();

    if (lowerBase == 'browser.exe' && executablePath.toLowerCase().contains('yandex')) {
      return 'Yandex Browser';
    }
    final known = _knownExecutableTitles[lowerBase];
    if (known != null) return known;

    final stem = base.toLowerCase().endsWith('.exe') ? base.substring(0, base.length - 4) : base;
    if (fallbackFolderName != null &&
        fallbackFolderName.trim().isNotEmpty &&
        !fallbackFolderName.toLowerCase().startsWith('app-') &&
        fallbackFolderName.toLowerCase() != 'bin' &&
        fallbackFolderName.toLowerCase() != 'application') {
      return fallbackFolderName.trim();
    }

    // Check parent directory name if stem is generic (`app`, `launcher`, `client`, `main`).
    if (parts.length >= 2) {
      final parent = parts[parts.length - 2];
      final parentLower = parent.toLowerCase();
      if (parentLower.startsWith('app-') && parts.length >= 3) {
        return _humanizeIdentifier(parts[parts.length - 3]);
      }
      if ((stem.toLowerCase() == 'launcher' || stem.toLowerCase() == 'client' || stem.toLowerCase() == 'browser') &&
          parentLower != 'bin' &&
          parentLower != 'application') {
        return _humanizeIdentifier(parent);
      }
    }

    return _humanizeIdentifier(stem);
  }

  static String _humanizeIdentifier(String raw) {
    final cleaned = raw.replaceAll(RegExp('[_-]+'), ' ').trim();
    if (cleaned.isEmpty) return raw;
    return cleaned
        .split(RegExp(r'\s+'))
        .map((word) {
          if (word.isEmpty) return word;
          if (word.toUpperCase() == word && word.length <= 5) return word;
          return word[0].toUpperCase() + word.substring(1);
        })
        .join(' ');
  }

  static String _stripQuotes(String value) {
    var result = value.trim();
    if (result.length >= 2 && result.startsWith('"') && result.endsWith('"')) {
      result = result.substring(1, result.length - 1).trim();
    }
    return result;
  }

  static Future<String> _defaultRegistryReader(List<String> arguments) async {
    if (!Platform.isWindows) return '';
    final result = await Process.run('reg.exe', arguments);
    if (result.exitCode != 0) return '';
    return (result.stdout ?? '').toString();
  }

  static Future<List<String>> _defaultRunningProcessPathsReader() async {
    if (!Platform.isWindows) return const <String>[];
    final result = await Process.run(
      'powershell.exe',
      const <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath } | Select-Object -ExpandProperty ExecutablePath -Unique',
      ],
    );
    if (result.exitCode != 0) return const <String>[];
    return (result.stdout ?? '')
        .toString()
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _defaultExeFinder(String directoryPath, {int maxDepth = 2}) {
    final root = Directory(directoryPath);
    if (!root.existsSync()) return const <String>[];
    final found = <String>[];

    void walk(Directory current, int depth) {
      if (depth > maxDepth) return;
      List<FileSystemEntity> entities;
      try {
        entities = current.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final entity in entities) {
        if (entity is File && entity.path.toLowerCase().endsWith('.exe')) {
          found.add(entity.path);
        } else if (entity is Directory && depth < maxDepth) {
          final name = entity.path.split(RegExp(r'[\\/]')).last.toLowerCase();
          if (name.startsWith('.') || name == 'locales' || name == 'resources' || name == 'swiftshader') {
            continue;
          }
          walk(entity, depth + 1);
        }
      }
    }

    walk(root, 0);
    return found;
  }
}
