// 激活窗口：未激活 / 被吊销 / 校验过期时挡住主界面，让用户在这里把授权走完。
//
// 这一页只回答两件事：
//   1. 我这台电脑的设备码是多少？（卡片 + 复制按钮 + 可选中文字）
//   2. 拿到激活码之后往哪儿填？（激活码卡片 + 粘贴按钮 + 激活）
//
// 中间的三步说明把这两件事之间的路写出来。页面上不显示授权服务器地址，
// 也不显示设备码的来源——用户要办的事只有「把码填进去」，这两样都属于
// 排查时才需要的东西，摆在眼前只会让人以为是必填项或者要核对的东西。
//
// ## 正式发版前请确认
// 构建命令里带了 --dart-define=ECHOS_LICENSE_URL=https://<你的 worker>。
// 没带的话 LicenseService 走 notConfigured 分支（不拦截），本页只能从主界面
// 状态栏右侧的「授权」那一小条主动点进来——那意味着发出去的是一份拦不住人的包。
import 'dart:async';
import 'dart:io' show Socket;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_identity.dart';
import '../services/license_service.dart';
import '../services/platform_drivers.dart';
import 'frosted.dart';
import 'theme.dart';
import 'widgets/app_button.dart';
import 'widgets/app_text_field.dart';

// 激活页不接回调：主界面是靠 LicenseService.changes 重建的，激活成功那一刻
// stream 会推一次 active，main.dart 的监听自己就切回 HomePage 了。
// 再从这边回调一次是重复动作，而且两处都判一遍状态容易走岔。
class ActivationPage extends StatefulWidget {
  const ActivationPage({super.key});

  @override
  State<ActivationPage> createState() => _ActivationPageState();
}

class _ActivationPageState extends State<ActivationPage> {
  final _svc = LicenseService.instance;
  String _code = '';
  String _tip = '';
  bool _busy = false;

  /// 哪个动作在进行：'activate' / 'auth'（重新校验）/ 'net'（检查网络）。
  /// _busy 是三者的总闸（互斥、进行中全部按钮禁用），但状态行的进行时
  /// 文案只属于 auth/net——「激活」的进行时显示在激活提示行（_tip）。
  /// 若共享一个进行时文案，点「激活」时状态行会跟着转「正在校验授权…」，
  /// 两个按钮看起来就联动了（用户口径：每个按钮对应自己的消息）。
  String? _busyAction;

  /// 激活提示行（_tip）的红字位：只由激活 / 粘贴 / 剪贴板 / TG 跳转的
  /// 失败置位，「重新校验」的结果不碰它。
  bool _actErr = false;

  /// 授权状态行的红字位：只由「重新校验」的结果置位，激活的成败不碰它。
  bool _authErr = false;

  StreamSubscription<LicenseStage>? _sub;

  /// 复制按钮的「已复制」态：点一下变绿色，2 秒后回到「复制」。
  bool _copied = false;
  Timer? _copiedTimer;

  /// 激活按钮的结果态：null = 正常「激活」；'ok' = 绿色「已激活」。
  /// 失败不进按钮（用户口径）——失败原因走提示行，按钮保持可重试。
  String? _activateResult;

  /// 卡片一的校验消息行：启动/重新校验/检查网络后如实显示校验进展
  ///（正在校验 / 连接失败与上次成功时间 / 通过后为空）。
  String _verifyMsg = '';

  /// 「检查网络」的结果（富文本单行：彩色符号 + 结论 + 灰字详情）。
  /// 纯文本装不下「符号带色」这件事，所以网络检查走这一个结构而非
  /// _verifyMsg——渲染时两者互斥，谁有内容显示谁。
  ({String symbol, Color color, bool ok, String text, String detail})? _verifySpan;

  /// 状态显示区当前归属哪个按钮的输出：
  /// null=初始快照（启动校验） / 'auth'=重新校验 / 'net'=检查网络。
  /// 独占制的开关：点检查网络置 'net'（授权结论整块让位），点重新
  /// 校验置 'auth'（网络结果整块让位）。
  String? _actionLine;

  /// 状态行的授权结论快照：只在授权动作（启动/重新校验）结束时刷新，
  /// 其他动作（检查网络/激活）触发的重建沿用上一条——否则检查网络
  /// 一点，状态行就把实时 stage 的「客户端授权已吊销」渲染出来，
  /// 看起来像检查网络产出了授权提示（用户原则：每个按钮对应一条
  /// 自己的消息）。初始为空：首帧前由 bootstrap 结果填充。
  String _authHeadline = '';

  /// 状态行结论的分类色快照（'red'/'gray'）。
  /// 存分类不存 Color：initState 里就要写快照，那时拿不到 Theme。
  String _authTone = 'gray';

  /// 弹窗里「点我去 TG 群」要跳的链接，激活页打开时向服务端取一次。
  /// 取不到就是空串，界面上不显示这个按钮——用户仍可以照下面写的
  /// 机器人命令去私聊机器人，那条路不依赖这个链接。
  String _inviteLink = '';

  /// 每次「粘贴」自增，用作激活码输入框的 key。
  ///
  /// AppTextField 的控制器在它自己内部，只在「未聚焦且外部值变了」时才回显
  /// （见 app_text_field.dart 的 didUpdateWidget）。用户点着输入框再点粘贴，
  /// 字段仍持有焦点，外部赋值会被那行判断挡掉，粘贴完框里还是旧内容。
  /// 换 key 让它整个重建，是唯一不必改通用组件的办法。
  int _pasteSeq = 0;

  @override
  void initState() {
    super.initState();
    _authHeadline = _headline(_svc.stage);
    _authTone = _toneOf(_svc.stage);
    _code = _svc.savedCode;
    _loadInviteLink();
    // 激活页是**接管性**页面：它出现的那一刻（被吊销/封禁），主界面上一切
    // 未决操作都已无意义。但首页换页只换 home 本身，弹在 home 之上的路由
    // （端口占用确认、删除服务器确认、WebDAV 对话框……）会原样浮在激活页
    // 上面，还点得动——用户对着一个已经没有后果上下文的弹窗按「确定」，
    // 或者只觉得界面坏了。这里把导航栈清到只剩第一层。
    // popUntil 的返回值落在各弹窗的「取消」分支上，那本来就是安全路径
    // （取消 = 不启动 / 不删除 / 不还原），不存在半完成状态。
    // initState 里不能直接 pop（首帧未画、栈未就绪），放到首帧之后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.popUntil((r) => r.isFirst);
    });
    // stream 是广播流，不归这一页所有：漏掉 cancel 的话，用户在首页和激活页之间
    // 来回切几次就会攒下好几个 setState，其中总有一个会打在已销毁的 State 上。
    _sub = _svc.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadInviteLink() async {
    final link = await _svc.fetchInviteLink();
    if (!mounted || link.isEmpty) return;
    setState(() => _inviteLink = link);
  }

  void _openInviteLink() {
    final err = openExternalUrl(_inviteLink);
    if (err == null) return;
    setState(() {
      _actErr = true;
      _tip = err;
    });
  }

  /// 从剪贴板取激活码填进框里。
  ///
  /// 不自动提交：粘进来的是不是本机的码只有服务端知道，先让用户看一眼
  /// 这串字符再决定要不要点「激活」。粘贴错台机器的码在实测里不少见，
  /// 自动提交等于把一次误操作直接变成一次失败弹窗。
  Future<void> _pasteCode() async {
    ClipboardData? d;
    try {
      d = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      // 剪贴板被别的进程占住时读不出来，这是 Windows 上真实会发生的。
      if (!mounted) return;
      setState(() {
        _actErr = true;
        _tip = '读不到剪贴板，请手动输入或用 Ctrl+V';
      });
      return;
    }
    final text = (d?.text ?? '').trim();
    if (!mounted) return;
    if (text.isEmpty) {
      setState(() {
        _actErr = true;
        _tip = '剪贴板里没有内容';
      });
      return;
    }
    setState(() {
      _code = text;
      _pasteSeq++;
      _actErr = false;
      // 粘贴换了码，上一次的激活结果随之作废（与手动输入同一条规矩），
      // 不然按钮和输入框还停在「已激活/激活失败」的旧结果色上。
      _activateResult = null;
      _tip = '已粘贴，点「激活」提交';
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _activate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyAction = 'activate';
      _tip = '正在校验…';
      _actErr = false;
      _activateResult = null;
    });
    final r = await _svc.activate(_code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyAction = null;
      // 激活失败也可能是因为连不上服务器：这时提示行留空，
      // 那句重复的话由副标题（状态行）承担。
      _tip = r.stage == LicenseStage.unreachable ? '' : r.message;
      _actErr = !r.ok;
      // 失败不改按钮：失败原因在提示行报告（红色），按钮保持「激活」
      // 让用户随时可重试——按钮一旦变成别的名字，提示行里"点「激活」"
      // 指的那颗按钮就不在页面上了。
      _activateResult = r.ok ? 'ok' : null;
    });
    // 激活成功 → 服务已切到 active，主界面靠 changes 事件换页。
    // 事件万一没送达，600ms 后重发一次：对已切换的实例是无害的
    // 幂等重建，对卡在本页的实例是确定性的解药。
    if (r.ok && r.stage == LicenseStage.active) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) LicenseService.instance.resync();
      });
    }
  }

  /// 进行时的状态行文案：跟触发按钮的语义对齐——
  /// 「重新校验」显示「正在校验授权…」，「检查网络」显示「正在检查网络…」。
  String get _busyLabel =>
      _busyAction == 'net' ? '正在检查网络…' : '正在校验授权…';

  /// 「检查网络」：纯网络探测——TCP 直连授权服务器的 443，结果单行
  /// 富文本（彩色符号 + 文案 + 灰字详情）。**不触发授权校验**（用户
  /// 拍板）：授权有自己的按钮（重新校验），检查完自动跑校验会把
  /// 授权结论混进网络结果。服务器域名/地址不落界面（页面头成文原则）。
  Future<void> _checkNetwork() async {
    if (_busy) return;
    // 客户端冷却：纯本机 TCP 探测对服务端零负担，连点没有意义，
    // 2 秒内的重复点击直接忽略（按钮不进「正在检查」假态）。
    final now = DateTime.now();
    if (_lastNetAt != null &&
        now.difference(_lastNetAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastNetAt = now;
    setState(() {
      _busy = true;
      _busyAction = 'net';
      _verifyMsg = '';
      _verifySpan = null;
      _actionLine = 'net';
    });
    final host = Uri.tryParse(LicenseService.baseUrl)?.host ?? '';
    if (host.isEmpty) {
      // 本地开发包（没注入授权地址）：真实用户永远到不了这一档，
      // 界面不留提示——暴露内部配置状态没有服务对象，排查靠 auth.log。
      if (!mounted) return;
      setState(() => _busy = false);
      return;
    }
    final sw = Stopwatch()..start();
    bool ok;
    Object? netErr;
    try {
      final sock = await Socket.connect(host, 443,
          timeout: const Duration(seconds: 6));
      sock.destroy();
      ok = true;
    } catch (e) {
      ok = false;
      netErr = e;
    }
    sw.stop();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyAction = null;
      final detail =
          ok ? '网络延迟 ${sw.elapsedMilliseconds} ms' : _netFailHint(netErr);
      _netLastOk = ok;
      _verifySpan = (
        symbol: ok ? '✅' : '❌',
        // 与主题 green/red 同源（0xFF30D158 / 0xFFFF3B30）：
        // 符号颜色即结论，一眼分通断。
        color: ok ? const Color(0xFF30D158) : const Color(0xFFFF3B30),
        ok: ok,
        text: ok ? '授权服务器连接成功' : '授权服务器连接失败',
        detail: detail,
      );
    });
  }

  /// TCP 探测失败的原因分类：口径与授权请求日志共用一份
  /// （LicenseService.describeNetError），认不出的措辞退回
  /// 「网络异常」，不引入新的失败路径。
  String _netFailHint(Object? e) {
    final s = LicenseService.describeNetError(e);
    return s ?? '网络异常，请检查本机网络';
  }

  Future<void> _reverify() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyAction = 'auth';
      // 校验进行中：由状态行覆盖显示（见卡片二布局），
      // 消息行只留给结果细节。上一次检查网络的结果一并清掉：
      // 独占制——点重新校验，整个状态区就只属于授权校验。
      _verifySpan = null;
      _actionLine = 'auth';
    });
    final r = await _svc.verify(force: true, source: '用户手动'); // 用户按钮：击穿 TTL
    if (!mounted) return;
    // 授权校验结束：状态行刷新为本轮结论——「重新校验」这个按钮的
    // 消息归它（用户原则：每个按钮对应一条消息）。
    _authHeadline = _headline(_svc.stage);
    _authTone = _toneOf(_svc.stage);
    setState(() {
      _busy = false;
      _busyAction = null;
      _authErr = !r.ok;
      // 校验的结果细节写在按钮上方的消息行：连不上时给出上次成功校验的
      // 时间尾巴；「维持原结论」的断网答复（硬拦档位被保留，见
      // _handleUnreachable）没有尾巴，就明写「连接失败」。通过后清空
      // （状态行由结论快照承担）。
      if (!r.ok) {
        final tail = r.message
            .replaceFirst('授权服务器连接失败，请检查网络', '')
            .trim();
        _verifyMsg = tail.isEmpty
            ? '授权服务器连接失败，请检查网络'
            : tail.replaceFirst('（', '').replaceFirst('）', '');
      } else {
        _verifyMsg = '';
      }
    });
  }

  // 复制的和窗口里显示的同一串（带连字符）：粘到 TG 里直接就能发；
  // 服务端 normalizeDeviceCode 对带不带连字符都规整，两种写法都收。
  // 成功反馈就在按钮上：复制 → 绿色「已复制」，2 秒后还原。
  // 不再额外弹 SnackBar——按钮变没变色，视线不用离开卡片就知道。
  Future<void> _copyDeviceCode() async {
    await Clipboard.setData(ClipboardData(text: DeviceIdentity.current));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final stage = _svc.stage;
    final errored = _actErr || _authErr || _stageBad(stage);
    // 状态行的进行时只属于授权/网络动作：点「激活」时这一行保持上一条结论
    // 不动——「激活」的进行时由激活提示行（_tip）自己承担，两边各说各的。
    final statusBusy = _busy && _busyAction != 'activate';

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [EchTheme.bgTop(t), EchTheme.bg(t)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: CardBox(
                // 上下留白比左右多一档：副标题上方和底部按钮下方都要有呼吸空间，
                // 内容在卡片里读起来是「居中偏松」，不是顶着边框排。
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
                tint: errored ? EchTheme.red : EchTheme.blue,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(
                          errored
                              ? Icons.error_outline
                              : Icons.verified_user_outlined,
                          size: 20,
                          color: errored ? EchTheme.red : EchTheme.blue,
                        ),
                        const SizedBox(width: 8),
                        Text('客户端授权',
                            style: TextStyle(
                                fontSize: EchTheme.fsGroupTitle,
                                fontWeight: EchTheme.fwTitle,
                                letterSpacing: EchTheme.letterSpacing,
                                color: EchTheme.titleText(t))),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // 内层卡片一：注册激活。步骤、两张码卡片和动作按钮，
                    // 从上到下就是操作的先后顺序。提示行也在这里：
                    // 它只剩一个职责——报告「激活」的结果。
                    _sectionCard(t, children: [
                      Text('💭 注册激活步骤',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: EchTheme.fwTitle,
                              letterSpacing: EchTheme.letterSpacing,
                              color: EchTheme.text(t))),
                      const SizedBox(height: 10),
                      ..._stepItems(t),
                      const SizedBox(height: 14),
                      _deviceCard(t),
                      if (_showInput(stage)) ...[
                        const SizedBox(height: 12),
                        _codeCard(t),
                        // 执行结果显示在激活码与按钮中间：它报告的是
                        // 「刚才那次激活怎么了」，离触发它的按钮最近又
                        // 不挡在卡片和按钮之间。不设固定高度——两行长文案
                        // 在 18px 的框里第二行会压到第一行上，看起来重叠。
                        if (_tip.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(_tip,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: EchTheme.smallStyle(
                                  _activateResult == 'ok'
                                      ? EchTheme.blue
                                      : (_actErr
                                          ? EchTheme.red
                                          : EchTheme.textSoft(t)))),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            // 跳转在前、激活在后：激活是这一行的主动作，
                            // 常规对话框约定里最重的按钮放在最右。
                            if (_inviteLink.isNotEmpty) ...[
                              Expanded(
                                child: AppButton('点我去 TG 群',
                                    height: 40,
                                    fontSize: EchTheme.fsAction,
                                    fontWeight: EchTheme.fwTitle,
                                    enabled: !_busy,
                                    focusable: false,
                                    onPressed: _openInviteLink),
                              ),
                              const SizedBox(width: 10),
                            ],
                            Expanded(
                              // 两态：蓝「激活」/ 绿「已激活」。失败不改按钮
                              // （原因走提示行），按钮永远叫「激活」可重试。
                              child: AppButton(
                                  _activateResult == 'ok' ? '已激活' : '激活',
                                  gradient: _activateResult == 'ok'
                                      ? EchTheme.greenGradient()
                                      : EchTheme.blueGradient(),
                                  height: 40,
                                  fontSize: EchTheme.fsAction,
                                  fontWeight: EchTheme.fwTitle,
                                  // 空码也放行点击：点了好在提示行里报
                                  //「请输入激活码」，比灰按钮少一次困惑。
                                  enabled: !_busy,
                                  focusable: false,
                                  onPressed: _activate),
                            ),
                          ],
                        ),
                        // 按钮行距卡片底部 30：内边距 22 之外再补 8。
                        const SizedBox(height: 8),
                      ] else if (_inviteLink.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        AppButton('点我去 TG 群',
                            height: 40,
                            fontSize: EchTheme.fsAction,
                            fontWeight: EchTheme.fwTitle,
                            enabled: !_busy,
                            focusable: false,
                            onPressed: _openInviteLink),
                        if (_tip.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(_tip,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: EchTheme.smallStyle(
                                  _activateResult == 'ok'
                                      ? EchTheme.blue
                                      : (_actErr
                                          ? EchTheme.red
                                          : EchTheme.textSoft(t)))),
                        ],
                      ],
                    ]),
                    const SizedBox(height: 10),
                    // 内层卡片二：状态与网络操作。校验的成功/失败全部由
                    // 副标题（随 stage 变化）反映，只有这一行，没有第二行。
                    _sectionCard(t, children: [
                      // 状态显示区（按钮上方，用户口径）：**动作独占**——
                      // 点哪个按钮，整个区就只显示那个按钮的结果，上一个
                      // 动作的结论不残留。_actionLine 记录当前区归属：
                      //   null      初始快照（进激活页那一刻的授权结论，
                      //             来源是启动校验，页面打开即可读）
                      //   'auth'    重新校验的输出（进行时→结论+细节）
                      //   'net'     检查网络的输出（彩色符号+详情），
                      //             期间授权结论一行都不在场
                      if (_actionLine == 'net') ...[
                        // 进行时（_busy 且结果未出）：显示「正在检查网络…」——
                        // 之前这里渲染的是「…」占位符，用户看到的是先一个
                        // 省略号再跳结果，进行时文案根本没出场。
                        if (statusBusy && _verifySpan == null) ...[
                          Text(_busyLabel,
                              style: EchTheme.bodyStyle(EchTheme.textSoft(t))),
                        ] else ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(_verifySpan?.symbol ?? '',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: _verifySpan?.color)),
                            if ((_verifySpan?.symbol ?? '').isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Text(_verifySpan!.text,
                                  style: EchTheme.smallStyle(
                                      _verifySpan!.ok
                                          ? EchTheme.blue
                                          : EchTheme.red)),
                              const SizedBox(width: 16),
                              Flexible(
                                child: Text(_verifySpan!.detail,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: EchTheme.smallStyle(
                                        EchTheme.textMuted(t))),
                              ),
                            ],
                          ],
                        ),
                        ],
                      ] else ...[
                        Text(
                            statusBusy ? _busyLabel : (_authHeadline.isEmpty ? ' ' : _authHeadline),
                            style: statusBusy
                                ? EchTheme.bodyStyle(EchTheme.textSoft(t))
                                : EchTheme.bodyStyle(_authTone == 'red'
                                    ? EchTheme.red
                                    : EchTheme.textMuted(t))),
                        // 授权校验的细节（上次成功时间）：只在授权线内显示。
                        if (_actionLine == 'auth' && _verifyMsg.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(_verifyMsg,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: EchTheme.smallStyle(EchTheme.textSoft(t))),
                        ],
                      ],
                      const SizedBox(height: 16),
                      // 状态按钮行：常驻。两个按钮常规都是非高亮的描边样式，
                      // 颜色走主题（日间/夜间自适应）；连不上服务器时
                      // 「检查网络」变红色胶囊并把视线引过去。
                      // 两者做的是同一件事（重试校验），重新校验是主动作，
                      // 按对话框约定放在最右。
                      Row(
                        children: [
                          Expanded(
                            // 红色胶囊的两个条件（见 _netLastOk 的注释）：
                            // 还没查过且授权不可达，或最近一次检查失败。
                            child: (_netLastOk == null &&
                                        stage == LicenseStage.unreachable) ||
                                    _netLastOk == false
                                ? AppButton('检查网络',
                                    gradient: EchTheme.redGradient(),
                                    height: 40,
                                    fontSize: EchTheme.fsAction,
                                    fontWeight: EchTheme.fwTitle,
                                    enabled: !_busy,
                                    focusable: false,
                                    onPressed: _checkNetwork)
                                : AppButton('检查网络',
                                    height: 40,
                                    fontSize: EchTheme.fsAction,
                                    fontWeight: EchTheme.fwTitle,
                                    enabled: !_busy,
                                    focusable: false,
                                    onPressed: _checkNetwork),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: AppButton('重新校验',
                                height: 40,
                                fontSize: EchTheme.fsAction,
                                fontWeight: EchTheme.fwTitle,
                                enabled: !_busy,
                                focusable: false,
                                onPressed: _reverify),
                          ),
                        ],
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 两张卡片共用同一个壳：小标签 + 内容 + 右侧一个动作按钮。
  ///
  /// 「设备码」和「激活码」的差别只有标签、内容和那个按钮上写什么，
  /// 壳自己拆成两份的话，改一次圆角要改两处，迟早漏一处。
  /// [actionGradient] 非空时按钮变成渐变胶囊（复制成功的绿色「已复制」）。
  Widget _card(ThemeData t, String label, Widget child,
      {String? actionLabel,
      VoidCallback? onAction,
      bool busy = false,
      Gradient? actionGradient}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: EchTheme.inputBg(t),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: EchTheme.cardBorder(t)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: EchTheme.smallStyle(EchTheme.textMuted(t))),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: child),
              if (actionLabel != null) ...[
                const SizedBox(width: 10),
                AppButton(actionLabel,
                    gradient: actionGradient,
                    enabled: !busy,
                    focusable: false,
                    onPressed: onAction,
                    minWidth: 62),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 设备码：可整段选中（用户也可以手动框选复制），旁边给一个复制按钮。
  /// 复制成功时按钮变绿色「已复制」，2 秒后还原。
  Widget _deviceCard(ThemeData t) {
    return _card(
      t,
      '设备码',
      SelectableText(
        DeviceIdentity.grouped,
        style: TextStyle(
            fontSize: EchTheme.fsInput,
            fontWeight: EchTheme.fwContent,
            letterSpacing: 0.6,
            fontFamily: EchTheme.monoFont,
            color: EchTheme.inputText(t)),
      ),
      actionLabel: _copied ? '已复制' : '复制',
      onAction: _copyDeviceCode,
      busy: _busy,
      actionGradient: _copied ? EchTheme.greenGradient() : null,
    );
  }

  /// 激活码：与上面两张卡片同一个壳，只是内容换成可输入的字段，
  /// 按钮换成「粘贴」——激活码是从 TG 复制来的，粘贴是主要动作。
  Widget _codeCard(ThemeData t) {
    return _card(
      t,
      '激活码',
      AppTextField(
        _code,
        key: ValueKey(_pasteSeq),
        hint: 'ECHS-XXXX-XXXX-XXXX-XXXX',
        // 提示（示例）恒为灰；填入的码默认跟主题文字色，激活成功变蓝——
        // 和激活按钮同一套结果指示：成功才变色，失败不碰输入框
        //（原因在提示行说），按钮保持「激活」可重试。
        textColor: _activateResult == 'ok' ? EchTheme.blue : null,
        onChanged: (v) {
          _code = v;
          // 改了码，上一次的激活结果就作废：按钮回到「激活」。
          if (_activateResult != null) {
            setState(() => _activateResult = null);
          }
        },
      ),
      actionLabel: '粘贴',
      onAction: _pasteCode,
      busy: _busy,
    );
  }

  /// 内层分区卡片：外层大卡片里的两个功能区，磨砂玻璃质感——
  /// 半透明填充透出外层卡片的渐变底，深浅两个模式各一档浓度。
  /// 不用 BackdropFilter：卡片本身不透明、也没有内容从区块后面滚过，
  /// 真模糊算不出可感知的差异，白付一层滤镜的成本。
  Widget _sectionCard(ThemeData t, {required List<Widget> children}) {
    final dark = EchTheme.isDark(t);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: .09)
            : const Color(0xFF0A84FF).withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: .14)
              : const Color(0xFF0A84FF).withValues(alpha: .16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  // 注册激活步骤的四行（不含小标题——标题由内层卡片二自己画）。
  // 四步讲完从复制设备码到激活的全流程；
  // 第 ④ 步的「点个Star」是真超链接，落到仓库主页。
  List<Widget> _stepItems(ThemeData t) {
    Widget line(int n, String title, Widget detail) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: EchTheme.blue.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Text('$n',
                    style: TextStyle(
                        fontSize: EchTheme.fsCaption,
                        fontWeight: EchTheme.fwTitle,
                        color: EchTheme.blue)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: EchTheme.labelStyle(EchTheme.textSoft(t))),
                    const SizedBox(height: 2),
                    detail,
                  ],
                ),
              ),
            ],
          ),
        );

    return [
      line(1, '复制本机<设备码>',
          Text('一机一码，注意保护个人隐私。',
              style: EchTheme.smallStyle(EchTheme.textMuted(t)))),
      line(2, '跳转 TG 授权群注册本机获取激活码',
          Text('暂时仅签发TG用户，签发后状态会变成「激活码已签发」。',
              style: EchTheme.smallStyle(EchTheme.textMuted(t)))),
      line(3, '将<激活码>粘贴到「激活码」卡片，点击「激活」',
          Text('激活码形如 ECHS-XXXX-XXXX-XXXX-XXXX，请妥善保管。',
              style: EchTheme.smallStyle(EchTheme.textMuted(t)))),
      line(4, '帮助与反馈', _helpDetail(t)),
    ];
  }

  // 第 ④ 步的详情：两行说明 + 一个真超链接（点「点个Star」打开仓库主页）。
  // 用 Wrap 而不是 RichText+TapGestureRecognizer：TapGestureRecognizer 要
  // 手动 dispose，漏掉就是泄漏；InkWell 的点击语义也更清楚。
  Widget _helpDetail(ThemeData t) {
    final linkStyle = EchTheme.smallStyle(EchTheme.blue).copyWith(
      decoration: TextDecoration.underline,
      decorationColor: EchTheme.blue,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('公益项目，避免传播与滥用设置了注册激活机制，如有问题请提交issue。',
            style: EchTheme.smallStyle(EchTheme.textMuted(t))),
        const SizedBox(height: 2),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('开源不易，帮忙', style: EchTheme.smallStyle(EchTheme.textMuted(t))),
            InkWell(
              onTap: () => openExternalUrl('https://github.com/nerder-real/EchOS-Win'),
              child: Text('点个Star⭐', style: linkStyle),
            ),
            Text('吧~', style: EchTheme.smallStyle(EchTheme.textMuted(t))),
          ],
        ),
      ],
    );
  }

  /// 「检查网络」最近一次的结果：null = 还没查过。红色胶囊的条件：
  /// 没查过且当前授权不可达，或最近一次检查失败。
  bool? _netLastOk;

  /// 「检查网络」最近一次点击时刻（2 秒冷却用，见 _checkNetwork）。
  DateTime? _lastNetAt;

  /// 状态行文案 + 分类色的口径：服务端明确说不（未登记/吊销/封禁/
  /// 连不上）与待用户操作（码已签发）都算需要被看见的结论，红字；
  /// 其余（校验停用、未配置、进行中等）灰。
  String _toneOf(LicenseStage s) {
    switch (s) {
      case LicenseStage.unregistered:
      case LicenseStage.codeIssued:
      case LicenseStage.revoked:
      case LicenseStage.banned:
      case LicenseStage.unreachable:
        return 'red';
      default:
        return 'gray';
    }
  }

  /// 盾牌/边框的"错误"判定比状态行窄一档：码已签发是流程中段不是故障，
  /// 头部保持蓝色；只有真正的拦下状态才红。
  bool _stageBad(LicenseStage s) =>
      s == LicenseStage.unregistered ||
      s == LicenseStage.revoked ||
      s == LicenseStage.banned ||
      s == LicenseStage.unreachable;

  String _headline(LicenseStage s) {
    switch (s) {
      case LicenseStage.unregistered:
        return '客户端暂「未授权」，请访问TG群获取激活码。';
      case LicenseStage.codeIssued:
        return '激活码「已签发」，请将激活码粘贴到输入框后，点击「激活」完成注册。';
      case LicenseStage.revoked:
        return '客户端授权「已吊销」，如有问题请联系管理员反馈。';
      case LicenseStage.banned:
        return '客户端授权「已被封禁」，如有问题请联系管理员反馈。';
      case LicenseStage.unreachable:
        return '授权服务器连接失败，请检查网络。';
      case LicenseStage.unknown:
        // 冷启动/校验在途：进行时由按钮上方的消息行（_verifyMsg）单点
        // 报告「正在校验授权…」。副标题不再重复同样的话——两行一样的字
        // 看起来像凭空新增了一条，也违反「消息只占一行」的原则。
        return '';
      default:
        // enforcementOff（服务端关闭强制校验）不落一字：管理端的开关状态
        // 不对客户端暴露。notConfigured（本地开发包）同样落空。
        return '';
    }
  }

  // 只有本地开发包（没配授权服务器）才藏输入框——填了也没意义。
  // 已吊销状态保留输入框：管理员「恢复」后，原码即刻重新可用，
  // 用户直接再点「激活」就能救回来，不需要先懂什么「重新校验」。
  bool _showInput(LicenseStage s) => s != LicenseStage.notConfigured;
}
