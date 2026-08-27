import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';
import 'package:loggy/loggy.dart';
import 'package:path/path.dart' as p;
import 'package:zeon/core/model/directories.dart';
import 'package:zeon/gen/zeon_core_generated_bindings.dart';
import 'package:zeon/singbox/model/core_status.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:zeon/zeoncore/core_interface/core_interface.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:zeon/zeoncore/generated/v2/hello/hello.pb.dart';
import 'package:zeon/zeoncore/generated/v2/hello/hello_service.pbgrpc.dart';

final _logger = Loggy('ZeonCoreFFI');
typedef StopFunc = Pointer<Utf8> Function();
typedef StopFuncDart = Pointer<Utf8> Function();

class CoreInterfaceDesktop extends CoreInterface with InfraLogger {
  static const managementHost = "127.0.0.1";
  static const _startupValidationGuard = bool.fromEnvironment("zeon_windows_startup_validation");
  static final ZeonCoreNativeLibrary _box = _gen();

  static ZeonCoreNativeLibrary _gen() {
    String fullPath = "";
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      fullPath = "hiddify-core";
    }
    if (Platform.isWindows) {
      fullPath = p.join(fullPath, "hiddify-core.dll");
    } else if (Platform.isMacOS) {
      fullPath = p.join(fullPath, "hiddify-core.dylib");
    } else {
      fullPath = p.join(fullPath, "hiddify-core.so");
    }

    _logger.debug('zeon-core native libs path: "$fullPath"');
    final lib = DynamicLibrary.open(fullPath);
    // final stopFunc = lib.lookup<NativeFunction<StopFunc>>('stop').asFunction<StopFunc>();
    // final errPtr2 = stopFunc();
    // final err = errPtr2.cast<Utf8>().toDartString();

    return ZeonCoreNativeLibrary(lib);
  }

  Future<bool> isMusl() async {
    try {
      final result = await Process.run('ldd', ['--version']);
      return result.stdout.toString().toLowerCase().contains('musl');
    } catch (_) {
      return false;
    }
  }

  int? _port;
  Future<String>? _setupOperation;
  int _sessionGeneration = 0;
  bool _coreStarted = false;
  static String generateRandomPassword(int length) {
    const characters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random();
    return List.generate(length, (_) => characters[random.nextInt(characters.length)]).join();
  }

  static final String secret = generateRandomPassword(100);

  @override
  Future<String> setup(Directories directories, bool debug, int mode) async {
    final existing = _setupOperation;
    if (existing != null) return existing;
    final operation = _setupOnce(directories, debug, mode);
    _setupOperation = operation;
    try {
      return await operation;
    } catch (_) {
      _setupOperation = null;
      rethrow;
    }
  }

  Future<String> _setupOnce(Directories directories, bool debug, int mode) async {
    // A fixed desktop port can attach ZEON to an unrelated Hiddify-derived
    // process. Allocate a process-owned loopback endpoint instead.
    final port = await _allocateLoopbackPort();
    _port = port;
    const channelOption = ChannelCredentials.insecure();
    final helloClient = HelloClient(
      ClientChannel(
        managementHost,
        port: port,
        options: const ChannelOptions(credentials: channelOption),
      ),
    );

    final err = using((arena) {
      final errPtr = _box.setup(
        directories.baseDir.path.toNativeUtf8(allocator: arena).cast(),
        directories.workingDir.path.toNativeUtf8(allocator: arena).cast(),
        directories.tempDir.path.toNativeUtf8(allocator: arena).cast(),
        SetupMode.GRPC_NORMAL_INSECURE.value,
        "$managementHost:$port".toNativeUtf8(allocator: arena).cast(),
        secret.toNativeUtf8(allocator: arena).cast(),
        0,
        debug ? 1 : 0,
      );
      try {
        return errPtr.cast<Utf8>().toDartString();
      } finally {
        _box.freeString(errPtr);
      }
    });
    if (err.isNotEmpty) {
      _port = null;
      return err;
    }
    final res = await _sayHelloWhenReady(helloClient);
    loggy.info("desktop core management endpoint ready: ${res.message.isNotEmpty}");

    bgClient = fgClient = CoreClient(
      ClientChannel(
        managementHost,
        port: port,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
          // credentials: ChannelCredentials.secure(
          //   password: secret,
          //   onBadCertificate: (certificate, host) => true,
          // ),
        ),
      ),
    );

    return "";
  }

  Future<int> _allocateLoopbackPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      return socket.port;
    } finally {
      await socket.close();
    }
  }

  Future<HelloResponse> _sayHelloWhenReady(HelloClient client) async {
    Object? lastError;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        return await client.sayHello(
          HelloRequest(name: "zeon-management-readiness"),
          options: CallOptions(timeout: const Duration(milliseconds: 500)),
        );
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(Duration(milliseconds: 50 + attempt * 25));
      }
    }
    throw StateError("desktop core management endpoint failed: ${lastError.runtimeType}");
  }

  @override
  Future<BackgroundSetupResult> setupBackground(String path, String name, {int generation = 0}) async {
    await setSessionGeneration(generation);
    _coreStarted = false;
    if (_startupValidationGuard) {
      loggy.warning("Windows startup validation guard blocked an explicit VPN start");
      return BackgroundSetupResult(
        generation: generation,
        status: const CoreStatus.stopped(message: "VPN disabled by startup validation artifact"),
      );
    }
    if (!isInitialized() || _port == null) {
      return BackgroundSetupResult(
        generation: generation,
        status: const CoreStatus.stopped(message: "desktop core management endpoint is unavailable"),
      );
    }
    return BackgroundSetupResult(generation: generation, status: const CoreStarting());
  }

  @override
  Future<void> setSessionGeneration(int generation) async {
    if (generation <= 0 || generation == _sessionGeneration) return;
    if (generation < _sessionGeneration) {
      throw StateError("stale desktop VPN generation");
    }
    _sessionGeneration = generation;
  }

  @override
  Future<void> markCoreStarted(int generation) async {
    if (generation != _sessionGeneration) {
      throw StateError("cannot mark stale desktop VPN generation ready");
    }
    _coreStarted = true;
  }

  @override
  Future<bool> restart(String path, String name) async {
    return false;
  }

  @override
  Future<bool> stop({int generation = 0}) async {
    if (generation > 0) await setSessionGeneration(generation);
    _coreStarted = false;
    // The shared lifecycle already stops the service over gRPC. The desktop
    // management endpoint is process-owned and remains ready for a later
    // explicit user start.
    return true;
  }

  @override
  Future<CoreStatus?> resyncSessionStatus() async =>
      _coreStarted ? const CoreStatus.started() : const CoreStatus.stopped();

  @override
  Future<bool> isActiveFg() async {
    final port = _port;
    return port != null && await isPortOpen(managementHost, port);
  }

  @override
  Future<bool> isActiveBg({PortProbeObserver? onPortProbe}) => isActiveFg();

  @override
  Future<bool> isBgClientAvailable() => isActiveBg();

  Future<bool> isPortOpen(String host, int port) async {
    try {
      final socket = await Socket.connect(host, port, timeout: const Duration(milliseconds: 300));
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
