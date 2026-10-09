import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'services/app_paths.dart';
import 'services/app_state.dart';
import 'services/instance_guard.dart';
import 'services/kernel_manager.dart';
import 'services/license_service.dart';
import 'services/system_proxy.dart';
import 'services/tray_service.dart';
import 'ui/home_page.dart';
import 'ui/activation_page.dart';
import 'ui/theme.dart';

/// 点右上角关闭 → 隐藏到托盘（进程继续），真正退出走托盘「退出应用」。
///
/// 未激活（锁定态）时是另一条路：直接退进程。留在托盘里等于留了一条
/// 绕开激活窗口的路——用户关掉窗口，再从托盘「显示应用」，回来的是
/// 同一个激活窗口，可这中间他完全可以去点别的入口。这条路一旦开着，
/// 拦截就只剩个界面效果。锁定口径 = LicenseService.uiLocked（与主界面
/// 门控、托盘菜单共用同一把锁）。
///
/// 会话中途的「连不上授权服务器」刻意不算锁定（见 uiLocked）：那多半
/// 是已激活用户赶上网络或服务端抖动，此刻照常隐藏到托盘，正在服务的
/// 隧道不殃及，恢复后复查自动回到 active。若在这里一刀切退进程，等于
/// 客户端替服务器执行了一次吊销。启动即断网且从未可用属于锁定——
/// 那台机器没有可保护的会话，关窗照锁定口径退出。
class _HideOnClose with WindowListener {
  @override
  void onWindowClose() {
    if (LicenseService.instance.bootstrapped &&
        LicenseService.instance.uiLocked) {
      // 走托盘那套完整收尾（停内核 → 还原系统代理 → 排空日志）而不是裸 exit：
      // 用户可能是开着隧道时后台复查判定被吊销的，此刻系统代理还接管着，
      // 直接退出会给这台机器留下一个打不开网页的代理设置。
      TrayService.instance.quit();
      return;
    }
    windowManager.hide();
  }
}

/// 强制居中：窗口尺寸变化后始终回到屏幕中央（最大化时不处理）。
class _KeepCentered with WindowListener {
  @override
  void onWindowResized() async {
    if (!(await windowManager.isMaximized())) {
      await windowManager.center();
    }
  }
}

/// 窗口可见性 → 空闲轮询的门控，外加「亮出来就校验一次」。
///
/// 托盘驻留的空闲实例不发密集轮询（its 状态由推送、慢速兜底和任何
/// 操作时的校验对齐）；用户把窗口亮出来的那一刻是最需要真相的时候——
/// show 事件顺手补一发校验，配合 resume 校验双保险。事件万一不来
/// （历史遗留的平台差异），行为退回「照常轮询」，安全降级。
class _WindowVis with WindowListener {
  @override
  void onWindowEvent(String eventName) {
    if (eventName == 'show') {
      // 窗口显示（启动首屏 / 托盘唤起 / 从托盘回前台都走这里）：
      // 用户可感知的事件，击穿 TTL
      LicenseService.instance.verify(force: true, source: '窗口显示');
    }
  }
}

/// 单实例锁 + 二次启动唤起的 IPC 端口已抽到 services/instance_guard.dart ——
/// 「以管理员身份重启」需要在交接窗口里主动放开它们，见该文件顶部说明。

/// 监听安装器授权标记，收到后自动退出应用。
///
/// 使用 `File.watch`（底层 ReadDirectoryChangesW）完全异步，不阻塞 UI isolate；
/// 对比原 `Timer.periodic(500ms)` + `Process.runSync('tasklist')` 方案，
/// 彻底消除了每半秒 10-40ms 的 UI 卡顿。
///
/// 监听范围：%TEMP% 目录。安装器向导页勾选「自动退出」或静默安装时写入
/// `EchOS_Install_Go.marker`，本函数探测到即触发退出流程。
StreamSubscription? _installWatchSub;

void _watchForInstaller() {
  _installWatchSub?.cancel();
  final tempDir = Directory(Directory.systemTemp.path);
  // Windows 下 File.watch 监听的是目录级事件，过滤出目标文件名即可。
  _installWatchSub = tempDir.watch().listen((event) async {
    if (event is FileSystemCreateEvent ||
        event is FileSystemModifyEvent) {
      final name = event.path.split(Platform.pathSeparator).last;
      if (name == 'EchOS_Install_Go.marker') {
        _installWatchSub?.cancel();
        _installWatchSub = null;
        await _closeForInstall();
      }
    }
  }, onError: (_) {
    // 监听失败（如目录权限问题）静默放弃，不影响应用正常运行。
    _installWatchSub = null;
  });
}

/// 收到安装器授权后执行安全退出。
/// 收尾顺序：
///   1) 接管过系统代理 → shutdown() 还原；否则把「退出时在运行」状态落盘，
///      下次启动 restoreProxyIfNeeded 自动续接。绝不能让死内核挂着死代理。
///   2) 若磁盘上留有更早实例异常退出的代理接管备份 → restoreFromDisk() 一并还原。
///   3) x-tunnel.exe 是独立进程，直接 exit 不会带走它；安装器替换该文件会报
///      access denied / code 5，故先路径校验清理，仍有残留则按镜像名兜底强杀。
Future<void> _closeForInstall() async {
  try {
    final app = AppState.instance;
    if (app.isRunning || app.isStarting) {
      // shutdown() 已含完整收尾：还原系统代理 → 停内核 → 记录「退出时在
      // 运行」供下次启动自动恢复 → persist() → 关日志。绝不能让死内核
      // 挂着死代理。
      await app.shutdown();
    } else {
      // 未运行：仅清理上次异常退出可能残留的接管备份。必须用默认的
      // clear:true —— 还原后删除备份，否则下次启动 recoverFromUncleanExit()
      // 会再次发现备份、重复还原，并误报「检测到上次异常退出」。
      await SystemProxy.restoreFromDisk();
      app.persist();
    }
  } catch (_) {}
  try {
    // 兜底：无论是否成功接管过代理，都尝试清理一次残留内核。
    await KernelManager.instance.killLeftovers();
  } catch (_) {}
  exit(0);
}

/// 安装互斥体：应用存活期间持有 Local\EchOS_App_Install，安装器「正在运行的
/// 应用」页据此判定本次是否需要自动退出（CheckForMutexes 探测到才显示该页）。
/// 句柄长期持有即进程存活期间生效；win32 包未收录 CreateMutexW，用
/// dart:ffi + package:ffi 绑定，句柄不显式关闭即长期存活。
final ffi.DynamicLibrary _kernel32 = ffi.DynamicLibrary.open('kernel32.dll');

void _acquireInstallMutex() {
  try {
    final createMutexW = _kernel32.lookupFunction<
        ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.NativeType> lpAttr,
            ffi.Int32 bInitialOwner,
            ffi.Pointer<ffi.Uint16> lpName),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.NativeType> lpAttr,
            int bInitialOwner, ffi.Pointer<ffi.Uint16> lpName)>(
        'CreateMutexW');
    final name = 'Local\\EchOS_App_Install'.toNativeUtf16().cast<ffi.Uint16>();
    createMutexW(ffi.nullptr, 0, name);
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 已有实例：唤起其窗口后必须显式退出进程（Flutter 桌面端 main() return 不结束进程）
  if (await InstanceGuard.claimOrWake()) exit(0);
  _acquireInstallMutex(); // Inno AppMutex 探测用，仅首次存活实例持有
  _watchForInstaller();   // 监听安装器授权标记，收到后自动安全退出
  await windowManager.ensureInitialized();
  // fire-and-forget：此后双击图标/再启动即唤起主窗口。
  // 回调里用 windowManager 显示窗口，避免 InstanceGuard 依赖 window_manager。
  InstanceGuard.startWakeListener(() async {
    await windowManager.show();
    await windowManager.focus();
  });
  const opts = WindowOptions(
    size: Size(796, 900),
    minimumSize: Size(796, 400),
    center: true,
  );
  windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
    // 标题栏无文字（任务栏悬停名来自 exe 资源 + 开始菜单快捷方式）
    await windowManager.setTitle('');
    // 恢复系统默认：可最小化/最大化（各平台原生标题栏按钮）
    await windowManager.setMinimizable(true);
    await windowManager.setMaximizable(true);
    await windowManager.setClosable(true);
    // 允许程序调整窗口大小
    await windowManager.setResizable(true);
    // 关闭按钮不再退出进程：拦截后隐藏到托盘
    windowManager.addListener(_HideOnClose());
    await windowManager.setPreventClose(true);
    // 强制居中：任何尺寸变化都回到屏幕中央
    windowManager.addListener(_KeepCentered());
    // 窗口可见性门控 + 亮出即校验（见 _WindowVis 的注释）。
    windowManager.addListener(_WindowVis());
  });
  await TrayService.instance.init();
  AppState.instance.persist();
  SystemProxy.initBackupDir(AppPaths.appDataDir.path);
  // runApp 提前：窗口立即可见，启动页只放 LOGO + EchOS，联网校验期间
  // 不是白板。校验完成后由 changes 事件切换到主界面/激活页——
  // 主界面绝不会先于校验结果出现。
  runApp(const EchOSApp());
  // 授权校验排在最前面：没激活过就不该起任何隧道相关的初始化。
  // bootstrap() 内部先读本地状态再联网，卡顿时最长十几秒，这段时间界面
  // 停在启动页上，校验本身不对用户说话。
  await LicenseService.instance.bootstrap();
  // 崩溃自愈只动本地（还原残留代理、清残留内核），与联网校验并行；
  // 两件都落地后再决定要不要恢复上次的代理。
  await AppState.instance.recoverFromUncleanExit();
  // 未激活不自动恢复上次的代理——没有本地凭证的断网（含从未激活）与
  // LicenseService 的 fail-closed 口径一致；留有「上次校验成功」时间戳的
  // 断网不拦（拦新不杀旧跨重启，见 blocked 的注释）——直连被劫持的环境
  // 里正是这个恢复把校验救活的：隧道一跑，校验经隧道就能到服务器。
  if (!LicenseService.instance.blocked) {
    AppState.instance.restoreProxyIfNeeded();
  } else if (LicenseService.instance.stage == LicenseStage.unknown) {
    // 首验被限流等场景尚无结论（429 维持「上一次」，新进程没有上一次）：
    // 结论一到就补这个恢复决定。没有这一笔，限流窗口会把提权重启承诺的
    // 「自动恢复代理」永远错过。
    late final StreamSubscription<LicenseStage> sub;
    sub = LicenseService.instance.changes.listen((s) {
      if (s == LicenseStage.unknown) return;
      sub.cancel();
      if (!LicenseService.instance.blocked) {
        AppState.instance.restoreProxyIfNeeded();
      }
    });
  }
  // 对齐 Mac：启动 3 秒后静默检查更新（App 版本 + 分流数据）。
  // 被拦下的客户端连更新源都不该再碰。
  Future.delayed(const Duration(seconds: 3), () {
    if (LicenseService.instance.blocked) return;
    AppState.instance.checkEverything(silent: true);
  });
}


/// 启动页：联网校验完成前的过渡。
///
/// **只放主页面那个 LOGO + EchOS**，不出现任何「校验授权 / 连接服务器 / 失败重试」
/// 字样，也不放进度圈。启动这几秒里授权校验是纯后台动作，界面上说破它等于
/// 把内部流程摊给用户看，还容易让人以为程序卡住了——校验期间唯一该有的观感
/// 是「程序起来了」，其余等结果出来由主界面/激活页自己讲。
///
/// 不显示主界面（校验没过不该出现），也不显示激活页（还没出结果，显示哪个
/// 状态都是错的）。
class _BootPage extends StatelessWidget {
  const _BootPage();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 与首页标题栏同一枚 LOGO（立体云位图 + 圆角裁剪），同款构图。
            // 尺寸取三档效果图的「小」档（52/30）：三档对比后用户拍板。
            Container(
              width: 52,
              height: 52,
              clipBehavior: Clip.antiAlias,
              decoration:
                  BoxDecoration(borderRadius: BorderRadius.circular(10)),
              child: Image.asset('assets/logo.png',
                  fit: BoxFit.cover, filterQuality: FilterQuality.high),
            ),
            const SizedBox(width: 12),
            const Text('EchOS',
                style: TextStyle(
                    fontSize: 30, fontWeight: EchTheme.fwTitle)),
          ],
        ),
      ),
    );
  }
}

class EchOSApp extends StatefulWidget {
  const EchOSApp({super.key});

  @override
  State<EchOSApp> createState() => _EchOSAppState();
}

class _EchOSAppState extends State<EchOSApp> with WidgetsBindingObserver {
  // 授权状态由 LicenseService 单点持有，这里只订阅变化并重建。
  // 被吊销这类变化发生在后台定时复查里（用户可能正把窗口收在托盘），
  // 必须能把主界面收走，不能只提示一下就放人继续用。
  StreamSubscription<LicenseStage>? _licenseSub;

  // 切断前隧道是否在跑：吊销/封禁切断时置位，恢复回 active 且隧道未起时
  // 据此自动续跑（对称闭环，见监听器里的恢复分支）。
  bool _tunnelWasRunning = false;

  // 显式记录当前亮度，替代 ThemeMode.system：Windows 桌面端在系统明暗来回
  // 切换时 platformBrightness 偶尔不主动通知重建，导致残留旧的深/浅色。
  // 这里监听 didChangePlatformBrightness 强制 setState，切换即刷新。
  Brightness _brightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _licenseSub = LicenseService.instance.changes.listen((s) async {
      if (!mounted) return;
      final app = AppState.instance;
      // 服务器明确说「不行」（未登记 / 码被换 / 码已发未领 / 被吊销 / 被封禁）时，
      // 正在跑的隧道要一并停掉——只把主界面换成激活窗口是不够的：换掉了
      // 界面，隧道照样在跑、系统代理照样接管着，这个客户端仍然是「可用」的。
      //
      // unreachable 刻意不在内：那多半是已激活用户赶上网络或服务端抖动，
      // 不是「服务器说他不行」。为一次抖动停掉正在服务的隧道、把人扔去
      // 激活页，等于客户端替服务器执行了一次吊销；恢复 active 后隧道也
      // 不会自己回来。会话的存续交给 hardBlocked 判定，unreachable 只拦
      // 「新的启动」，不停「正在跑的」。
      if (LicenseService.instance.hardBlocked) {
        if (app.isRunning || app.isStarting) {
          // 记住「切断前隧道在跑」：管理员恢复授权回到 active 时，
          // 据此自动续跑（见下面的恢复分支）。
          _tunnelWasRunning = true;
          await app.stop();
        }
      } else if (s == LicenseStage.active &&
          _tunnelWasRunning &&
          !app.isRunning &&
          !app.isStarting) {
        // 吊销→恢复的闭环：切断前在跑的隧道，恢复回 active 就自动续跑，
        // 省掉用户手动点「启动」的一步。触发时机是「状态翻回 active」
        // （恢复授权 / 重新激活成功），用户的原意（隧道在跑）没有变过，
        // 中途的切断是管理侧强加的，恢复就物归原主。
        _tunnelWasRunning = false;
        app.log('[授权] 授权已恢复，自动续跑代理');
        unawaited(app.start());
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _licenseSub?.cancel();
    super.dispose();
  }

  /// 托盘常驻时应用可能几天不获得焦点，光靠 6 小时一次的定时复查不够——
  /// 定时器在系统休眠时根本不跑。回到前台再问一次，顺手把「放了几天回来
  /// 发现已经被吊销」的情况提前处理掉。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      LicenseService.instance.verify(force: true, source: '回前台'); // 回前台是用户可感知事件：击穿 TTL
    }
  }

  @override
  void didChangePlatformBrightness() {
    final b = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (b != _brightness) {
      setState(() => _brightness = b);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EchOS',
      debugShowCheckedModeBanner: false,
      theme: EchTheme.light(),
      darkTheme: EchTheme.dark(),
      themeMode: _brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: !LicenseService.instance.bootstrapped ||
              LicenseService.instance.stage == LicenseStage.unknown
          ? const _BootPage()
          // 「unknown = 还没有任何结论」时同样留在启动页：bootstrap 已完
          // 但结论缺席只会发生在首验被 429 限流的场景（限流维持上一次
          // 结论，而新进程没有上一次）——TUN 提权重启的焦点风暴正好能
          // 撞出这个档。此时进授权弹窗等于展示一页没有结论的空壳
          //（状态行空白、卡片空转），按 retryAfter 的补射几秒到一分钟内
          // 必到，启动页等它即可。
          // 用 hardBlocked 而不是 blocked：unreachable（连不上服务器）不切
          // 激活页——那一刻隧道多半还在正常服务，整页切成激活窗而代理
          // 照跑，用户看到的就是「弹窗了却不断网」。unreachable 留在主界面
          // 由状态栏红字提示，拦新不杀旧，重试由客户端自动重试链承担。
          //
          // 例外：**启动首验就是 unreachable** 且从未可用过——这台机器此刻
          // 连「上一秒还好好的」都没有，主界面没有可保的会话，拦新就该连
          // 界面一起拦：落在激活页（授权弹窗）等自动重试链拉回，那里有
          // 「检查网络」按钮，正是 unreachable 的自助入口；一旦校验通过，
          // changes 事件自动切回主界面。口径收在 LicenseService.uiLocked，
          // 托盘菜单的缩减用的是同一把锁。
          : LicenseService.instance.uiLocked
              ? const ActivationPage()
              : const HomePage(),
    );
  }
}
