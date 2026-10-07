// 设备码：这台机器的「身份证」，授权流程的起点。
//
// ## 为什么必须是稳定且唯一的
// 服务端把「激活码 ↔ 设备码」在签发时就绑死，客户端换台机器就得重新走一遍流程。
// 因此这里的取值要满足三条：
//   1. 同一台机器重启、升级、换网络、换用户名都不变；
//   2. 重装系统 / 格式化系统盘 / 换硬盘之后会变（变了就说明确实是另一台「机器」）；
//   3. 推不出来（不依赖 MAC、CPU 序列号这类能被改或能被虚拟化的字段）。
//
// ## 取哪几个值（按优先级从强到弱，能读到几项就拼几项）
//   1. 主板 SMBIOS UUID   Win32_ComputerSystemProduct.UUID
//      —— 「这块主板就是这台机器」的权威标识，重装系统通常不变，
//         双系统（Windows + Linux）读出来是同一个值。微软官方与各类授权
//         方案都推崇它。唯一性最强，排在最前。
//   2. MachineGuid        HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid
//      —— Windows 每装一次系统生成一次，重装必变。
//   3. 系统盘序列号      GetVolumeInformationW(<系统盘>)
//      —— 格式化必变，换硬盘必变。
//
// 这里不是「拿到第一项就用」，而是**读到几项就拼几项**：三项各有各的用处，
// 少一项不会让标识失效（降级而已），多一项则多一道区分。优先级只决定
// 界面上 sourceLabel 怎么描述，以及哪一项缺失时值得担心。
//
// ## 为什么 UUID 优先但仍然拼上 MachineGuid
// 只用 UUID 会丢掉「重装系统即换码」这条属性：UUID 在重装后不变，设备码
// 就不会变，用户重装系统后旧激活码会继续被认。拼上 MachineGuid 之后，
// 重装仍会换码，而 UUID 的价值变成两件事：
//   · MachineGuid 偶然重复时（克隆系统、批量装机用同一模板）多一道区分；
//   · 给管理员一个跨重装稳定的主板标识，排查时能认出「是同一块板」。
//
// ## 为什么哈希而不是直接用
// UUID 和 MachineGuid 都是能定位到一台机器的稳定标识，没有理由明文发出去：
// 前者是主板序列，后者是系统级标识。哈希之后发出去的是摘要，既能当设备码，
// 又不泄露原始标识。
//
// 摘要不是原样输出，而是映到 32 个字符的字母表上取 16 位，得到 ECHC-XXXX-XXXX-XXXX-XXXX：
//   · 字母表去掉了 I / O / 0 / 1，人工抄写和口述都不容易错，激活页上念给客服听也听得清；
//   · 16 位 × 5 bit = 80 bit 熵。设备码是要贴到 TG 里、抄到工单上的，短比熵值钱，
//     而 80 bit 配合服务端「每次兑换都要打一次 KV」，在线爆破到不现实；
//   · 4 位一组是均匀切分，每组好念好比对，抄错哪一段一眼能看出来。
//
// ## 为什么 UUID 有两条读取路径
// 读 UUID 有两个办法，快慢和适用范围差得很远：
//   FFI 读固件表   GetSystemFirmwareTable('RSMB') 解析 SMBIOS 结构表。
//                  纯原生调用，微秒级，不起子进程。但部分机器上整个接口返回
//                  ERROR_INVALID_FUNCTION（实测黑苹果 / EFI 环境即如此），
//                  所以它只能是首选、不能是唯一。
//   子进程查 CIM   powershell Get-CimInstance Win32_ComputerSystemProduct。
//                  哪里都能用，但要拉起解释器，实测约 0.5~1 秒。
// 先试 FFI，失败再花那个时间，且必须隐藏窗口（否则每次算设备码都闪一个黑框）。
//
// ## 读不到怎么办
// 注册表被精简、跑在非 Windows 上、权限不足时可能读不到，逐级降级到底。
// 全部读不到时退回「系统版本 + 主机名」的摘要，宁可弱一点也不让客户端起不来。
// 弱在哪：主机名可以改，稳定性不如前几级；但换机器依然会换码，
// 而「稳定」这件事此时退化为「同一台机器不改主机名就一直是同一个码」。
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

// ---- 设备码的书写格式 ----
//
//   ECHC-XXXX-XXXX-XXXX-XXXX
//
// 前缀由客户端自己带上，不靠服务端去猜来的是设备码还是激活码
// （激活码是 ECHS-，服务端签发）。服务端 License.js 里有同一份定义。
//
// 字母表和激活码共用：去掉了 I / O / 0 / 1 这四个在人工抄写时最容易认错的字符。
// 16 位 × 每字符 5 bit = 80 bit 熵，取 sha256 摘要的前 16 个字节，每个字节模 32
// 映一个字符。模 32 在这里没有偏斜：字节是 0~255，256 正好是 32 的整数倍。
// 选 80 bit 而不是更长，是为了激活页一行放得下、管理页表格里不横向撑开；
// 而 80 bit 配合服务端「每次兑换都要打一次 KV」，在线爆破不现实。
const String deviceCodePrefix = 'ECHC-';
const String codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const String activationCodePrefix = 'ECHS-';
const int _codeGroups = 4;
const int _codeGroupLen = 4;
const int _codeBodyLen = _codeGroups * _codeGroupLen; // 16

// 激活码的严格格式门：ECHS-XXXX-XXXX-XXXX-XXXX，大写、四组之间有连字符、
// 字母表 32 个字符。客户端在提交前先过这道门，格式不对就地拒绝。
//
// 服务端 License.js 的 normalizeCode 是宽容归一（大小写、连字符都能容），
// 那是给管理页粘贴各种来源的串兜底的；客户端面对的是用户本人，
// 静默把小写改成大写再发出去，激活记录里存的串和他抄的串对不上号，
// 排查时反而多一个岔。约定只有这一种写法，界面也只教这一种写法。
final RegExp activationCodeRe = RegExp(
    '^$activationCodePrefix[$codeAlphabet]{4}(-[$codeAlphabet]{4}){3}\$');

/// 激活码是否严格符合约定格式（大写、含连字符、字母表内字符）。
bool isValidActivationCode(String raw) => activationCodeRe.hasMatch(raw);

/// 把 sha256 摘要渲染成 ECHC-XXXX-XXXX-XXXX-XXXX。
///
/// 摘要要够 [_codeBodyLen] 个字节（sha256 有 32 个，绰绰有余）。
String _renderDeviceCode(List<int> digest) {
  if (digest.length < _codeBodyLen) {
    throw ArgumentError('摘要至少要 $_codeBodyLen 个字节，实际给了 ${digest.length}');
  }
  final chars = StringBuffer(deviceCodePrefix);
  for (var i = 0; i < _codeBodyLen; i++) {
    if (i > 0 && i % _codeGroupLen == 0) chars.write('-');
    chars.write(codeAlphabet[digest[i] % codeAlphabet.length]);
  }
  return chars.toString();
}

/// 设备码。整进程只算一次：[current] 带缓存。
class DeviceIdentity {
  static String? _cached;
  static String _source = '';

  static String get current => _cached ??= compute();

  /// 分组显示。分组纯粹为了人读和手抄，粘到 TG 里仍然可以直接去掉连字符。
  static String get grouped => current;

  /// 指纹来源说明，用于在界面上如实告诉用户「这台机器的标识是怎么来的」。
  /// 走了回退分支时这句会变成弱口径，管理员排查时能一眼看出来。
  static String get sourceLabel {
    _cached ??= compute();
    return _source;
  }

  static String compute() {
    final parts = <String>[];

    if (Platform.isWindows) {
      // 一级：主板 UUID。拿到就用，格式校验在 _readSmbiosUuid 内部做。
      // 纯 FFI 读固件表，微秒级；读不到才花时间起子进程查 CIM。
      final uuid = _readSmbiosUuid();
      if (uuid != null) {
        parts.add('uuid:$uuid');
        _source = '主板 SMBIOS UUID';
      }

      // 二级：MachineGuid。重装系统必变，UUID 读不到时的替补。
      final guid = _readMachineGuid();
      if (guid.isNotEmpty) parts.add('mg:$guid');

      // 三级：系统盘序列号。只在 UUID 与 MachineGuid 都缺时才需要它顶上来，
      // 正常机器上前两级已经足够，这里是有它就加、没有也不影响判定。
      final serial = _readSystemVolumeSerial();
      if (serial != null) parts.add('vs:$serial');

      // 只要不是彻底空档就算强标识。UUID 在时它是最强的一级；
      // 没有 UUID 时，MachineGuid + 卷序列号仍然构成原来的双保险。
      if (parts.isEmpty) parts.add('nosig');
    }

    if (parts.isEmpty) {
      parts
        ..add('fallback')
        ..add(Platform.operatingSystem)
        ..add(Platform.operatingSystemVersion)
        ..add(Platform.localHostname);
      _source = '系统版本 + 主机名（弱指纹）';
    } else if (!_source.isNotEmpty) {
      _source = _describe(parts);
    }

    final digest = sha256.convert(utf8.encode(parts.join('|')));
    return _renderDeviceCode(digest.bytes);
  }

  /// 没拿到 UUID 时的来源说明。按实际读到的项组合说出来，
  /// 管理员在激活页一眼能看出这台机器的标识是强是弱。
  static String _describe(List<String> parts) {
    bool has(String p) => parts.any((x) => x.startsWith(p));
    if (has('mg:') && has('vs:')) return '系统 MachineGuid + 系统盘序列号';
    if (has('mg:')) return '系统 MachineGuid';
    if (has('vs:')) return '系统盘序列号（弱指纹）';
    // 三项都没读到：只剩占位的 nosig，如实说成读不到，而不是假装有标识。
    return '未能读取系统标识（弱指纹）';
  }
}

// ---------------------------------------------------------------------------
// Windows 读取（FFI）
//
// 字符串一律用 Pointer<Uint16> 出现在签名里：package:ffi 的 Utf16 不是
// SizedNativeType，不能直接放进 FFI 签名。toNativeUtf16() 的返回值在调用处
// .cast<Uint16>() 转一下即可，和 main.dart 里 CreateMutexW 的写法一致。
// ---------------------------------------------------------------------------

const int _hkeyLocalMachine = 0x80000002;
const int _keyRead = 0x20019;
const int _keyWow64_64key = 0x0100;
const int _winErrorSuccess = 0;
const int _regSz = 1;
const int _regExpandSz = 2;

/// 读 HKLM\SOFTWARE\Microsoft\Cryptography 的 MachineGuid。
/// 返回空串表示读不到（键不存在、被精简、非 Windows），调用方走回退分支。
String _readMachineGuid() {
  try {
    final advapi = ffi.DynamicLibrary.open('advapi32.dll');
    // HKEY 是指针宽度的句柄。dart:ffi 没有 IntPtr，预定义根键
    // （HKEY_LOCAL_MACHINE = 0x80000002）按 64 位无符号整数传：
    // Win64 ABI 走同一个寄存器，上半段在这个常量上是 0，行为与传指针一致。
    final regOpen = advapi.lookupFunction<
        ffi.Int32 Function(ffi.Uint64, ffi.Pointer<ffi.Uint16>, ffi.Uint32,
            ffi.Uint32, ffi.Pointer<ffi.Pointer<ffi.Void>>),
        int Function(int, ffi.Pointer<ffi.Uint16>, int, int,
            ffi.Pointer<ffi.Pointer<ffi.Void>>)>('RegOpenKeyExW');
    final regQuery = advapi.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Uint16>,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Uint32>),
        int Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Uint16>,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Uint32>)>('RegQueryValueExW');
    final regClose = advapi.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>),
        int Function(ffi.Pointer<ffi.Void>)>('RegCloseKey');

    final subKey =
        'SOFTWARE\\Microsoft\\Cryptography'.toNativeUtf16().cast<ffi.Uint16>();
    final valueName = 'MachineGuid'.toNativeUtf16().cast<ffi.Uint16>();
    final hKey = calloc<ffi.Pointer<ffi.Void>>();
    ffi.Pointer<ffi.Void> opened = ffi.nullptr;
    final size = calloc<ffi.Uint32>();
    final type = calloc<ffi.Uint32>();
    try {
      final rc = regOpen(
          _hkeyLocalMachine, subKey, 0, _keyRead | _keyWow64_64key, hKey);
      if (rc != _winErrorSuccess) return '';
      opened = hKey.value;

      // 第一遍只问长度：lpData 传 NULL 时 RegQueryValueExW 只回填所需字节数。
      // 先问再分配，避免拍一个「大概够」的缓冲区，也避免多留一段未初始化内存。
      if (regQuery(opened, valueName, ffi.nullptr, type, ffi.nullptr, size) !=
          _winErrorSuccess) {
        return '';
      }
      if (type.value != _regSz && type.value != _regExpandSz) return '';
      final bytes = size.value;
      if (bytes == 0 || bytes > 4096) return '';

      final buf = calloc<ffi.Uint8>(bytes);
      try {
        if (regQuery(opened, valueName, ffi.nullptr, type, buf, size) !=
            _winErrorSuccess) {
          return '';
        }
        return buf.cast<Utf16>().toDartString().trim();
      } finally {
        calloc.free(buf);
      }
    } finally {
      if (opened != ffi.nullptr) regClose(opened);
      calloc
        ..free(hKey)
        ..free(subKey)
        ..free(valueName)
        ..free(size)
        ..free(type);
    }
  } catch (_) {
    return '';
  }
}

/// 读系统盘（当前系统盘，不写死 C 盘）序列号。格式化或换盘即变。
/// 取不到返回 null —— 序列号本身可能为 0，那时没有区分度，别把它当标识用。
int? _readSystemVolumeSerial() {
  try {
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    final getVolInfo = kernel32.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Uint16>,
            ffi.Pointer<ffi.Uint16>,
            ffi.Uint32,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint16>,
            ffi.Uint32),
        int Function(
            ffi.Pointer<ffi.Uint16>,
            ffi.Pointer<ffi.Uint16>,
            int,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint16>,
            int)>('GetVolumeInformationW');

    // 不写死 "C:\\"：系统盘未必是 C（多系统盘、USB 启动的机器都可能不是）。
    final root = '${Platform.environment['SystemDrive'] ?? 'C:'}\\';
    final rootPtr = root.toNativeUtf16().cast<ffi.Uint16>();
    // 261 是 MAX_PATH；两个缓冲区都要，因为签名里这两参不能省。
    final nameBuf = calloc<ffi.Uint16>(261);
    final fsBuf = calloc<ffi.Uint16>(261);
    final serial = calloc<ffi.Uint32>();
    final maxComp = calloc<ffi.Uint32>();
    final flags = calloc<ffi.Uint32>();
    try {
      final ok =
          getVolInfo(rootPtr, nameBuf, 261, serial, maxComp, flags, fsBuf, 261);
      if (ok == 0) return null;
      final v = serial.value;
      return v == 0 ? null : v;
    } finally {
      calloc
        ..free(rootPtr)
        ..free(nameBuf)
        ..free(fsBuf)
        ..free(serial)
        ..free(maxComp)
        ..free(flags);
    }
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 主板 SMBIOS UUID
//
// 这是设备码的第一来源。两条读取路径，按速度依次尝试：
//   1. FFI 读固件表（微秒级，不起子进程）
//   2. 子进程查 CIM（哪里都能用，约 0.5~1 秒）
// 两条都失败、或拿到的值无效时返回 null，由调用方降级到 MachineGuid。
// ---------------------------------------------------------------------------

/// SMBIOS 结构表里「系统信息」（Type 1）的类型字节。
const int _smbiosTypeSystem = 1;

/// 固件表首部 8 字节：'_SM3_' / '_SM_' / '_DMI_' + 校验和 + 表长 + 版本。
const int _smbiosHeaderLen = 8;

/// 读主板 SMBIOS UUID。取不到或无效返回 null。
///
/// 先走 FFI 读固件表；只有在整张表读不到时才起子进程查 WMI。两条路径返回的
/// 都必须是规范的大写 UUID，格式不对一律当没读到。
String? _readSmbiosUuid() {
  final fast = _readUuidViaFirmwareTable();
  if (fast != null) return fast;

  final slow = _readUuidViaWmi();
  if (slow != null) return slow;

  return null;
}

// ---- 路径 1：FFI 读固件表 ----

/// 用 GetSystemFirmwareTable('RSMB') 读 SMBIOS 原始结构表并解出 UUID。
///
/// 快，但可用性看机器：部分机型（实测黑苹果 / EFI 环境）整个固件表接口返回
/// ERROR_INVALID_FUNCTION，此时返回 null，由调用方改走 WMI。
String? _readUuidViaFirmwareTable() {
  // 表长由表内的首部给出，但取表本身需要一个缓冲区。先用 64 KB——SMBIOS
  // 结构表实测远小于此，一次够用；读回来的长度以函数返回值为准。
  final cap = 64 * 1024;
  // calloc<Uint8>(n) 返回 Pointer<Uint8>，asTypedList 拿字节视图。
  final buf = calloc<ffi.Uint8>(cap);
  final bytes = buf.asTypedList(cap);

  // ProviderSignature 是 LPCSTR：指向 4 个字节的内存（'R','S','M','B'），
  // 不是以 \0 结尾的字符串，也不是一个能塞进整数的值。
  // 原生签名里 LPCSTR/PVOID 都是 void*，但 dart:ffi 的 cast<T>() 要求目标
  // 与来源有继承关系，Uint8→Char/Void 之间没有，所以这里直接用 Pointer<Uint8>
  // 声明形参类型：ffi 侧只按地址传值，元素类型不影响实际调用。
  final prov = calloc<ffi.Uint8>(4);
  prov.asTypedList(4)
    ..[0] = 0x52 // R
    ..[1] = 0x53 // S
    ..[2] = 0x4D // M
    ..[3] = 0x42; // B
  var got = 0;
  try {
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    // 原生签名：UINT GetSystemFirmwareTable(LPCSTR, UINT, PVOID, UINT)。
    // 形参声明成 Pointer<Uint8> 而非 Char/Void：ffi 只传地址，
    // 而 cast<T>() 不允许在无继承关系的 NativeType 之间转换。
    final getTable = kernel32.lookupFunction<
        ffi.Uint32 Function(ffi.Pointer<ffi.Uint8>, ffi.Uint32,
            ffi.Pointer<ffi.Uint8>, ffi.Uint32),
        int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>,
            int)>('GetSystemFirmwareTable');

    got = getTable(prov, 0, buf, cap);
    if (got <= _smbiosHeaderLen) return null;

    // 校验首部：'_SM3_' / '_SM_' / '_DMI_' 三种锚点都见过。
    final anchor = String.fromCharCodes(
        [bytes[0], bytes[1], bytes[2], bytes[3], bytes[4]]);
    if (anchor != '_SM3_' && anchor != '_SM_' && anchor != '_DMI_') {
      return null;
    }

    // SMBIOS 表头共 8 字节：锚点(5) + 校验和(1) + 表长(1) + 版本 major(1)。
    // 结构表紧跟表头从偏移 8 开始。UUID 的端序规则只依赖 major：2.x/3.x 是
    // 混端序，1.x（_DMI_）整段反序。
    final major = bytes[7];
    var off = _smbiosHeaderLen;
    while (off + 4 <= got) {
      final type = bytes[off];
      final len = bytes[off + 1];
      if (len < 4 || off + len > got) return null; // 结构长度不自洽，判为无效表

      if (type == _smbiosTypeSystem) {
        const uuidOff = 8; // 系统信息里 UUID 的偏移
        if (off + uuidOff + 16 > got) return null;
        final u = <int>[];
        for (var k = 0; k < 16; k++) {
          u.add(bytes[off + uuidOff + k]);
        }
        final List<int> be;
        if (major >= 2) {
          be = [
            u[3], u[2], u[1], u[0], u[5], u[4], u[7], u[6],
            u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15],
          ];
        } else {
          be = u.reversed.toList();
        }
        return _formatUuidBytes(be);
      }

      // 跳过本条及其附带的字符串表（连续非零串，以连续两个 0 结束）。
      var j = off + len;
      while (j + 1 < got) {
        if (bytes[j] == 0 && bytes[j + 1] == 0) {
          j += 2;
          break;
        }
        while (j < got && bytes[j] != 0) {
          j++;
        }
        j++;
      }
      off = j;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    calloc
      ..free(buf)
      ..free(prov);
  }
}

// ---- 路径 2：子进程查 WMI ----

/// 用 PowerShell 查 Win32_ComputerSystemProduct.UUID。
///
/// 只在 FFI 那条路读不到时才走，因此这个耗时（约 0.5~1 秒）付得值。
/// -WindowStyle Hidden 少了不闪黑框；-NoProfile 免读用户配置，避开其中的
/// 恶意 profile 钩子拖慢或劫持这次调用。
String? _readUuidViaWmi() {
  try {
    final r = Process.runSync(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Command',
        '(Get-CimInstance Win32_ComputerSystemProduct).UUID',
      ],
    );
    if (r.exitCode != 0) return null;
    return _uuidFromText(r.stdout.toString());
  } catch (_) {
    return null;
  }
}

/// 从子进程输出里取 UUID：先按占位串筛，再按字符取 32 个半字节，最后校验。
///
/// 顺序不能反：占位串 'None' / 'Not Specified' 里含有十六进制字符，
/// 若先取字符就会得到一个看似合法的 32 位值，把占位符当成真 UUID。
String? _uuidFromText(String raw) {
  final text = raw.trim().toUpperCase();
  if (text.isEmpty) return null;
  final squashed = text.replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (_uuidPlaceholders.contains(squashed)) return null;
  return _formatUuid(_parseUuidText(text));
}

/// 从一段文本里取出 UUID 的 32 个半字节（0~15 的数值）。
///
/// 非十六进制字符一律忽略，这样空格、连字符、以及 PowerShell 可能附带的
/// 换行/引号都不影响结果。每个十六进制字符拆成一个半字节——UUID 的
/// 8-4-4-4-12 一共 32 个十六进制字符，拆完正好 32 个半字节。
/// 注意 codeUnit 是字符编码（'D' 是 68），要先判断落在哪个区间再减去
/// 该区间起点，得到的才是半字节数值。
List<int> _parseUuidText(String s) {
  final out = <int>[];
  for (final ch in s.toUpperCase().codeUnits) {
    if (out.length == 32) break;
    if (ch >= 0x30 && ch <= 0x39) {
      out.add(ch - 0x30); // '0'-'9' → 0-9
    } else if (ch >= 0x41 && ch <= 0x46) {
      out.add(ch - 0x41 + 10); // 'A'-'F' → 10-15
    }
  }
  return out;
}

// ---- 格式校验与格式化 ----

/// 把 32 个半字节格式化成 8-4-4-4-12 的大写 UUID；无效返回 null。
///
/// 32 是硬要求：8-4-4-4-12 合计 32 个十六进制字符位，少一位就说明
/// 子进程输出被截断或格式不对，这种情况当没读到，不能凑合切。
///
/// 挡掉厂商没提供 UUID 时填的占位值，其中最常见的是全 F：
/// `FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF`。全 0 同理。这两种必须当没读到，
/// 否则同一批没填 UUID 的机器会算出同一个设备码。
String? _formatUuid(List<int> nibbles) {
  if (nibbles.length != 32) return null;

  var allF = true;
  var allZero = true;
  for (final n in nibbles) {
    if (n != 0xF) allF = false;
    if (n != 0) allZero = false;
  }
  if (allF || allZero) return null;

  // 每个半字节对应一个十六进制字符位：13 → "D"，9 → "9"。
  // toRadixString(16) 对 0~15 天然产出一位，拼 32 个正好 32 个字符。
  final h = nibbles.map((n) => n.toRadixString(16).toUpperCase()).join();
  return _assembleUuid(h);
}

/// 按 8-4-4-4-12 切分 32 个十六进制字符。入参长度由调用方保证。
String _assembleUuid(String h) => '${h.substring(0, 8)}-${h.substring(8, 12)}-'
    '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20, 32)}';

/// 把 16 个原始字节（每字节两个十六进制位）格式化成 8-4-4-4-12；无效返回 null。
///
/// 与 [_formatUuid] 的区别在入参：那一条收的是 32 个半字节（每字符一位，
/// 来自文本），这一条收的是 16 个字节（固件表里的原始值）。两条路径的
/// 数据形态不同，但输出的 UUID 必须是同一个写法，因此各自格式化、共享校验。
String? _formatUuidBytes(List<int> b) {
  if (b.length != 16) return null;

  var allF = true;
  var allZero = true;
  for (final v in b) {
    if (v != 0xFF) allF = false;
    if (v != 0x00) allZero = false;
  }
  if (allF || allZero) return null;

  final h = b
      .map((v) => v.toRadixString(16).toUpperCase().padLeft(2, '0'))
      .join();
  return _assembleUuid(h);
}

/// 占位串：厂商没填 UUID/序列号时填的内容，各不相同但都该当作没读到。
///
/// 这里的每个条目都必须**只含字母和数字**：比较前原文已被剔除所有非字母数字
/// 字符，写成 'To Be Filled By O.E.M.' 这样带点带空格的条目永远匹配不上。
const _uuidPlaceholders = <String>{
  'TOBEFILLEDBYOEM',
  'DEFAULTSTRING',
  'DEFAULTSERIALNUMBER',
  'NOTSPECIFIED',
  'UNKNOWN',
  'NONE',
  'NA',
  'SYSTEMSERIALNUMBER',
  'BASEBOARDSERIALNUMBER',
  'CHASSISSERIALNUMBER',
};
