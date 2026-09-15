class WindowsAutoStart {
  WindowsAutoStart({
    required this.appName,
    required this.executablePath,
    this.runKeyPath = r'Software\Microsoft\Windows\CurrentVersion\Run',
    this.approvedKeyPath = r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
  });

  final String appName;
  final String executablePath;
  final String runKeyPath;
  final String approvedKeyPath;

  bool isEnabled() => false;

  void enable() {}

  void disable() {}
}
