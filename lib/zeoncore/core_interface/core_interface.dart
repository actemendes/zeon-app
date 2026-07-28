import 'package:zeon/core/model/directories.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';

class CoreInterface {
  late CoreClient fgClient;
  late CoreClient bgClient;

  Future<String> setup(Directories directories, bool debug, int mode) async {
    return "";
  }

  Future<CoreStatus> setupBackground(String path, String name, {int generation = 0}) async {
    return const CoreStarted();
  }

  Future<bool> prepareVpn(String path, String name, bool disableMemoryLimit, {int generation = 0}) async {
    return true;
  }

  Future<bool> restart(String path, String name) async {
    return false;
  }

  Future<bool> stop({int generation = 0}) async {
    return false;
  }

  Future<bool> isBgClientAvailable() async {
    return true;
  }

  Future<void> setSessionGeneration(int generation) async {}

  bool isSingleChannel() {
    // return true;
    return fgClient == bgClient;
  }

  Future<bool> resetTunnel() async {
    return false;
  }

  Future<bool> isActiveFg() async {
    return true;
  }

  Future<bool> isActiveBg() async {
    return true;
  }

  bool isInitialized() {
    try {
      // ignore: unnecessary_statements
      bgClient; // touch it
      return true;
    } catch (_) {
      return false;
    }
  }
}
