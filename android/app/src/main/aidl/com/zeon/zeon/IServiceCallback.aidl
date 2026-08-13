package com.zeon.zeon;

interface IServiceCallback {
  void onServiceStatusChanged(int status, long generation);
  void onServiceAlert(int type, String message);
  void onServiceWriteLog(String message);
  void onServiceResetLogs(in List<String> messages);
}
