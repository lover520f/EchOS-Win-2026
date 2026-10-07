<#
.SYNOPSIS
    EchOS Windows 本地完整构建打包：内核 -> Flutter -> 安装包 -> 便携版

.DESCRIPTION
    最关键的一点：内核必须编译输出到 windows/bundle/x-tunnel.exe。

    原因：windows/runner/CMakeLists.txt 末尾挂了 POST_BUILD 钩子，调用
    copy_bundle.cmake，用 copy_if_different 把 windows/bundle 下的
    x-tunnel.exe / geoip.dat / geosite.dat 拷到产物目录。
    如果只把内核编译到 third_party/x-tunnel/，flutter build 会用 bundle 里
    的旧内核把产物覆盖掉 —— 结果是「代码改了、打包还是旧的」，且不报任何错。

    仓库里 windows/bundle/x-tunnel.exe 被 .gitignore 排除，不会推到 GitHub；
    CI 每次用 setup-go 从源码现编，所以远端永远是最新的。

.PARAMETER Version
    版本号，形如 1.0.1。同时注入到三处：ECHOS_VERSION / --build-name /
    ISCC /DAPP_VERSION。必须与即将打的 v* 标签一致，否则自动更新会静默失效。

    脚本开头会做版本一致性预检：与 pubspec.yaml、lib/services/app_version.dart
    比对。**低于 pubspec 版本时按「本地测试包」处理，只警告不阻断**，
    所以默认的 -Version 1.0.0 照常可用；高于或不一致时会报错退出。

.PARAMETER AllowVersionMismatch
    跳过版本一致性预检的硬性失败。只在「确实要构建一个版本号对不上的包、
    且确定不会拿它发版」时使用。

.PARAMETER Repo
    更新源 owner/repo，注入 ECHOS_REPO。

.PARAMETER LicenseUrl
    授权服务地址（Cloudflare Workers，形如 https://echos-license.<子域>.workers.dev），
    注入 ECHOS_LICENSE_URL。**填了才是「需要激活」的包**，不填则走 notConfigured
    分支，任何人都进得去。构建结束会拿产物里的 app.so 逐字节找这个字符串，
    找不到直接判失败——否则「忘了传参数」发出去的包看起来一切正常，
    唯一的表现是拦不住人。

.PARAMETER ResourceHacker
    便携版注入图标/版本信息用的 ResourceHacker.exe 完整路径。不传时依次找
    仓库内 Temp\echos-build\reshacker\ResourceHacker.exe、仓库内 tools\ 下同名文件、
    以及 PATH；**都找不到就自动从 angusj.com 下载一份到缓存目录**（约 6MB，
    与 CI 同源）。下载失败才退化为「便携版沿用 7-Zip 图标与版本信息」并给出警告
    ——那种情况下产物看起来一切正常，只有图标和「属性→详细信息」不对。

.EXAMPLE
    .\build_local.ps1
    .\build_local.ps1 -Version 1.0.2
    .\build_local.ps1 -Version 1.2.0 -LicenseUrl https://echos-license.abc.workers.dev
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [string]$Repo    = 'nerder-real/EchOS-Win',
    [string]$LicenseUrl = '',
    [string]$ResourceHacker = '',
    [switch]$SkipPortable,
    [switch]$AllowVersionMismatch
)

$ErrorActionPreference = 'Stop'
# 中文 Windows 控制台默认 GBK，UTF-8 中文会显示成乱码；统一按 UTF-8 输出
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$rel  = Join-Path $root 'build\windows\x64\runner\Release'

# 本机目录残留自检：跟踪文件里不允许出现历史工作目录名（仓库是位置无关的，
# 任何 clone 都不该带着某台机器的目录文案）。模式运行时组装，避免自命中。
# 不用 git grep：它「无匹配=退出码 1」的健康语义在 pwsh 7 下会被当成命令
# 失败（Windows PowerShell 5.1 则不会——本地一直没炸、CI 炸了两次就是它）。
# Select-String 的结果只由内容决定，与 shell 版本无关。
$leftoverPat = 'work' + 'buddy|z' + 'code'
$leftoverExts = @('.dart','.js','.html','.yml','.md','.ps1','.sh','.iss','.toml',
                 '.json','.go','.cmake','.cpp','.h','.txt','.isl','.rc','.tpl','.xml')
$leftover = @()
foreach ($lf in @(git -C $root ls-files)) {
    if ($leftoverExts -contains [IO.Path]::GetExtension($lf).ToLower()) {
        $lm = Select-String -LiteralPath (Join-Path $root $lf) -Pattern $leftoverPat -List -ErrorAction SilentlyContinue
        if ($lm) { $leftover += $lf }
    }
}
if ($leftover.Count -gt 0) {
    throw "跟踪文件里出现历史工作目录残留：$($leftover -join ', ')——清理后再构建"
}

# 构建中间产物（便携版归档、SFX 模块、ResourceHacker、wintun 下载缓存）统一放
# 仓库内 Temp\echos-build：完全跟随仓库走——项目 clone 到哪个目录、哪台机器，
# 缓存就在哪，不对「仓库外面还有个可写的同级目录」做任何假设（Temp/ 已在
# .gitignore 排除，与 /build/ 同一惯例）。SFX / ResourceHacker 缓存长期复用。
# 注意：这里只放构建产物。Go 的模块缓存（GOPATH）在 C:\Go\gopath，跟工具链走，
# 不要往这里挪；应用运行时数据（托盘图标、日志）在 %APPDATA%\EchOS，也不要放这。
$tmp = Join-Path $root 'Temp\echos-build'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Write-Host "  构建临时目录: $tmp" -ForegroundColor Gray

function Find-Exe {
    param([string[]]$Candidates, [string]$Name)
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-Checked {
    param([string]$What)
    if ($LASTEXITCODE -ne 0) { throw "$What 失败（exit=$LASTEXITCODE）" }
}

Write-Host "版本: $Version    更新源: $Repo" -ForegroundColor White
Write-Host ''

# ---------- 版本一致性预检 ----------
# 版本号散落在三处，任一处漏改都可能让「自动更新」静默失效（自报版本 ≥ Release
# 标签时，客户端永远判定「已是最新版本」，且不报任何错）：
#   1. -Version          本次构建注入的版本（exe 资源 + 应用自报版本）
#   2. pubspec.yaml      version: 1.1.0+11
#   3. app_version.dart  defaultValue: '1.1.0'（只在没传 --dart-define 时生效）
#
# 判定规则 —— 刻意不对「本地测试包」设卡，否则默认的 -Version 1.0.0 直接不可用：
#   三者一致                    → 通过
#   $Version 低于 pubspec 版本  → 判定为本地测试包，警告后继续
#   其余不一致                  → 报错退出（可用 -AllowVersionMismatch 跳过）
$reSemver    = '(\d+(?:\.\d+)*)'
$pubspecFile = Join-Path $root 'pubspec.yaml'
$dartFile    = Join-Path $root 'lib\services\app_version.dart'

$pubspecVer = $null
if (Test-Path $pubspecFile) {
    $m = Select-String -Path $pubspecFile -Pattern "^version:\s*$reSemver" | Select-Object -First 1
    if ($m) { $pubspecVer = $m.Matches[0].Groups[1].Value }
}
$dartVer = $null
if (Test-Path $dartFile) {
    $m = Select-String -Path $dartFile -Pattern "defaultValue:\s*'$reSemver'" | Select-Object -First 1
    if ($m) { $dartVer = $m.Matches[0].Groups[1].Value }
}

if (-not $pubspecVer -or -not $dartVer) {
    Write-Warning "版本预检跳过：读不到 pubspec.yaml($pubspecVer) 或 app_version.dart($dartVer)"
} else {
    # -Version 本身得是个能比较的版本号，否则下面的判定和 flutter --build-name 都会出问题
    $versionOk = $false
    try { $null = [version]$Version; $versionOk = $true } catch { }
    if (-not $versionOk) {
        throw "-Version '$Version' 不是合法版本号（应形如 1.1.0）。"
    }

    if ($pubspecVer -ne $dartVer) {
        Write-Warning "版本来源不同步：pubspec.yaml=$pubspecVer，app_version.dart=$dartVer —— 建议改成一致"
    }

    $isTestBuild = ([version]$Version) -lt ([version]$pubspecVer)

    if (($Version -eq $pubspecVer) -and ($Version -eq $dartVer)) {
        Write-Host "  版本预检通过：三处一致（$Version）" -ForegroundColor Green
    } elseif ($isTestBuild) {
        Write-Host "  版本预检：-Version $Version 低于 pubspec 的 $pubspecVer，按【本地测试包】处理" -ForegroundColor Yellow
        Write-Host "    这种包不能用于发版（自报版本会低于标签，客户端收不到更新）" -ForegroundColor DarkGray
    } elseif ($AllowVersionMismatch) {
        Write-Warning "版本不一致，但已指定 -AllowVersionMismatch，继续构建"
    } else {
        throw (@(
            '版本不一致，已中止构建：'
            "    -Version            = $Version"
            "    pubspec.yaml        = $pubspecVer"
            "    app_version.dart    = $dartVer"
            ''
            "发版前请把后两处都改成 $Version（两处都要改，漏改 app_version.dart 会让自动更新静默失效）。"
            '若只是本地试验、确定不发版，加 -AllowVersionMismatch 跳过本检查。'
        ) -join "`n")
    }
}
Write-Host ''

# ---------- 1/4 内核 ----------
# 直接输出到 windows/bundle/，保证 flutter build 拷的是刚编好的这一份。
# go / flutter 不一定在当前 shell 的 PATH 里（比如从 Git Bash 或某些终端启动），
# 这里显式按常见安装位置兜底查找，找不到再报错，避免中途莫名中断。
# Go 已统一到 C:\Go（GOROOT），兼容旧的 ~/sdk/go 布局
$go = Find-Exe @(
    'C:\Go\bin\go.exe',
    "$env:ProgramFiles\Go\bin\go.exe",
    "$env:USERPROFILE\sdk\go\bin\go.exe"
) 'go'
if (-not $go) { throw '未找到 go.exe，请安装 Go 或把 go 加入 PATH' }
# 预检：只判断「文件存在」不够。某些受限环境（沙箱/策略）会让 go.exe 启动即失败，
# 表现为无任何输出且 $LASTEXITCODE 保持为空 —— 到下面 Invoke-Checked 就只剩
# 「失败（exit=）」这种没有信息量的提示。这里先跑一次 go version 把问题说清楚。
$goProbe = & $go version 2>&1
if (-not $goProbe) {
    throw "go.exe 存在但无法执行（$go）。常见原因：当前终端被沙箱/安全策略限制了子进程启动。`n请在普通 PowerShell / 终端中重跑本脚本。"
}
Write-Host "  go: $goProbe" -ForegroundColor Gray

# Flutter 已统一到 C:\Flutter
$flutter = Find-Exe @(
    'C:\Flutter\bin\flutter.bat',
    'C:\src\flutter\bin\flutter.bat',
    "$env:USERPROFILE\flutter\bin\flutter.bat"
) 'flutter'
if (-not $flutter) { throw '未找到 flutter.bat，请安装 Flutter 或把 flutter 加入 PATH' }

Write-Host '=== 1/4 编译内核 -> windows/bundle/x-tunnel.exe ===' -ForegroundColor Cyan
$bundleExe = Join-Path $root 'windows\bundle\x-tunnel.exe'
Push-Location (Join-Path $root 'third_party\x-tunnel')
& $go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o "$bundleExe" .
Invoke-Checked '内核编译'
Pop-Location
Write-Host ("  内核 {0:N1} MB" -f ((Get-Item $bundleExe).Length / 1MB)) -ForegroundColor Green

# ---------- 1.5/4 分流数据 + wintun.dll ----------
# 必须在 flutter build 之前：copy_bundle.cmake 是 POST_BUILD 钩子，
# 构建时从 windows/bundle/ 把 geoip.dat / geosite.dat / wintun.dll 拷到产物目录。
# 仓库不携带这三个文件（.gitignore 已排除，与 CI 一样打包时下载）。
$bundleDir = Join-Path $root 'windows\bundle'
New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
foreach ($f in @('geoip.dat', 'geosite.dat')) {
    $dst = Join-Path $bundleDir $f
    if (-not (Test-Path $dst)) {
        Write-Host "  下载 $f ..." -ForegroundColor Gray
        Invoke-WebRequest "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" -OutFile $dst
    }
}

# wintun.dll：TUN 模式的硬依赖。内核按 LOAD_LIBRARY_SEARCH_APPLICATION_DIR 加载，
# 只认「与 x-tunnel.exe 同目录」，放别处等于没有 —— 所以必须随包发。
# 版本刻意钉死（不跟 latest）：TUN 驱动涉及系统网卡，跨版本行为可能变，
# 换个版本要重新验证。升级时同时改这里和 CI 工作流里的同一个常量。
$wintunVersion = '0.14.1'
$wintunDll = Join-Path $bundleDir 'wintun.dll'
if (-not (Test-Path $wintunDll)) {
    Write-Host "  下载 wintun.dll $wintunVersion ..." -ForegroundColor Gray
    $zip = Join-Path $tmp "wintun-$wintunVersion.zip"
    $xdir = Join-Path $tmp "wintun-$wintunVersion"
    Invoke-WebRequest "https://www.wintun.net/builds/wintun-$wintunVersion.zip" -OutFile $zip
    if (Test-Path $xdir) { Remove-Item -LiteralPath $xdir -Recurse -Force }
    # 用 .NET 解压，不额外依赖 7-Zip（便携版那步才需要 7z）
    Expand-Archive -LiteralPath $zip -DestinationPath $xdir -Force
    $src = Join-Path $xdir 'wintun\bin\amd64\wintun.dll'
    if (-not (Test-Path $src)) { throw "wintun 包里找不到 $src，检查下载内容" }
    Copy-Item $src $wintunDll -Force
}
Write-Host ("  wintun.dll {0:N0} KB" -f ((Get-Item $wintunDll).Length / 1KB)) -ForegroundColor Green

# ---------- 2/4 Flutter ----------
Write-Host '=== 2/4 Flutter Windows Release ===' -ForegroundColor Cyan
$defines = @(
    "--dart-define=ECHOS_VERSION=$Version",
    "--dart-define=ECHOS_REPO=$Repo"
)
if ($LicenseUrl) {
    # 去掉结尾的斜杠：客户端拼路径是 '$baseUrl/verify'，留着斜杠会变成 //verify，
    # 虽然大多数服务端能容忍，但没必要在包里留一个会让人犯疑的地址。
    $LicenseUrl = $LicenseUrl.TrimEnd('/')
    $defines += "--dart-define=ECHOS_LICENSE_URL=$LicenseUrl"
    Write-Host "  授权校验: 已启用 -> $LicenseUrl" -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host '  ┌───────────────────────────────────────────────────────────┐' -ForegroundColor Yellow
    Write-Host '  │ 警告：本次构建【不启用激活校验】                          │' -ForegroundColor Yellow
    Write-Host '  │                                                           │' -ForegroundColor Yellow
    Write-Host '  │ 没传 -LicenseUrl，客户端会走 notConfigured 分支——        │' -ForegroundColor Yellow
    Write-Host '  │ 任何人打开都能直接进主界面，一个包发出去拦不住。          │' -ForegroundColor Yellow
    Write-Host '  │ 要发「需要激活」的包，请加：                              │' -ForegroundColor Yellow
    Write-Host '  │   -LicenseUrl https://<worker>.<子域>.workers.dev          │' -ForegroundColor Yellow
    Write-Host '  └───────────────────────────────────────────────────────────┘' -ForegroundColor Yellow
    Write-Host ''
}
Push-Location $root
& $flutter build windows --release --build-name $Version @defines
Invoke-Checked 'Flutter 构建'
Pop-Location
# 校验：产物里的内核必须与刚编的一致，防止被 bundle 旧文件覆盖
$relExe = Join-Path $rel 'x-tunnel.exe'
$a = (Get-FileHash $bundleExe -Algorithm MD5).Hash
$b = (Get-FileHash $relExe   -Algorithm MD5).Hash
if ($a -ne $b) { throw "产物内核与源码编译结果不一致（$a vs $b），检查 copy_bundle.cmake" }
Write-Host '  产物内核 md5 校验一致' -ForegroundColor Green

# ---------- 2.5/4 授权校验是否真的编进去了 ----------
# 为什么非要查一遍字节：ECHOS_LICENSE_URL 是 String.fromEnvironment 的编译期常量，
# 漏传参数不会报错、不会警告，只会让客户端默默变成「不拦截」。
# 到了用户手里，表现是「授权功能好像没生效」，而那时包已经发出去了。
# 这里在产物里找那段地址：给地址了却找不到 = 注入失败；没给地址却在包里
# 发现了一个 workers.dev 字样 = 上一版没清干净的产物，比「本来就没启用」更麻烦。
$appSo = Join-Path $rel 'data\app.so'
if (-not (Test-Path $appSo)) { throw "产物里找不到 $appSo，Flutter 构建可能没走完" }
$soBytes = [IO.File]::ReadAllBytes($appSo)
$asAscii  = [Text.Encoding]::ASCII.GetString($soBytes)
if ($LicenseUrl) {
    if (-not $asAscii.Contains($LicenseUrl)) {
        throw "产物 app.so 里找不到授权地址 $LicenseUrl —— 注入没生效，这个包拦不住人，别发。"
    }
    Write-Host "  授权地址已确认编入产物（app.so）" -ForegroundColor Green
} else {
    if ($asAscii -match 'https://[a-z0-9.\-]*workers\.dev') {
        throw '产物 app.so 里出现了 workers.dev 地址，但本次没传 -LicenseUrl —— 疑似用了上一次构建的残留产物，别发。'
    }
    Write-Host '  已确认产物中不含授权地址（本包不拦截）' -ForegroundColor DarkGray
}

# ---------- 3/4 安装包 ----------
# 清空 Output，只保留本次构建的产物，避免历史版本越堆越多。
# 刻意放在打包前而不是脚本开头：内核或 Flutter 阶段万一失败，
# 上一次的产物还在，不会落得新旧两头空。
$outDir = Join-Path $root 'Output'
if (Test-Path $outDir) {
    Get-ChildItem -LiteralPath $outDir -Force |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Write-Host "  已清空 Output（只保留本次产物）" -ForegroundColor Gray

Write-Host '=== 3/4 Inno Setup 安装包 ===' -ForegroundColor Cyan
$iscc = Find-Exe @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) 'ISCC'
if (-not $iscc) { throw '未找到 ISCC.exe，请先安装 Inno Setup 6' }
& $iscc (Join-Path $root 'installer\EchOS.iss') "/DAPP_VERSION=v$Version"
Invoke-Checked 'Inno Setup 打包'

# ---------- 4/4 便携版 ----------
$setupExe = Join-Path $root "Output\EchOS-Win-v$Version-x64-Setup.exe"
Write-Host "  安装包: $setupExe" -ForegroundColor Green

if ($SkipPortable) {
    Write-Host '（已跳过便携版）' -ForegroundColor Yellow
    return
}

Write-Host '=== 4/4 7-Zip SFX 便携版 ===' -ForegroundColor Cyan
$7z = Find-Exe @(
    "$env:ProgramFiles\7-Zip\7z.exe",
    'D:\Program Files\7-Zip\7z.exe',
    "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
) '7z'
if (-not $7z) { throw '未找到 7z.exe，请先安装 7-Zip' }

# 4.1 在 Release 目录内压缩，归档条目平铺（echos.exe 在根，SFX 才能直接运行）
$arc = Join-Path $tmp 'echos_portable.7z'
Push-Location $rel
& $7z a -t7z -y "$arc" * | Out-Null
Invoke-Checked '7z 压缩'
Pop-Location

# 4.2 SFX 模块（需支持 ;!@Install@! 配置，故用 7zSD 而非 7-Zip 自带的 7z.sfx）
# 只缓存「下载解压」这一步 —— 7zsd_extra 是网络下载，慢且内容不变。
# 复制和注入资源每次都重做：注入依赖本机的 ResourceHacker，缺它时整块会跳过。
# 若把跳过后那份「没图标」的 SFX 也缓存下来，一次缺工具就会把结果永久固化，
# 之后即使补上工具也再不会重新注入 —— v1.1.0 便携版一直显示 7-Zip 图标就是这个原因。
$sfxSrc = Join-Path $tmp '7zsd_x\7zsd_LZMA2_x64.sfx'
if (-not (Test-Path $sfxSrc)) {
    Write-Host '  下载 7zSD SFX 模块...' -ForegroundColor Gray
    $dl = Join-Path $tmp '7zsd.7z'
    Invoke-WebRequest 'https://raw.githubusercontent.com/OlegScherbakov/7zSFX/master/files/7zsd_extra_170_3900.7z' -OutFile $dl
    & $7z x "$dl" "-o$(Join-Path $tmp '7zsd_x')" -y | Out-Null
}
# 文件名带版本号：版本资源按当前版本注入，不能跨版本共用同一个文件
$sfx = Join-Path $tmp "iconed-$Version.sfx"
Copy-Item $sfxSrc $sfx -Force

# 4.3 用 ResourceHacker 替换 SFX 的两套资源（只改资源，不动可执行功能）
$rh = if ($ResourceHacker) {
    $ResourceHacker
} else {
    Find-Exe @(
        (Join-Path $tmp 'reshacker\ResourceHacker.exe'),
        (Join-Path $root 'tools\ResourceHacker.exe')
    ) 'ResourceHacker.exe'
}
# 找不到就自动下载一份到缓存目录。**这一步不能省**：脚本原来只查找不获取，
# 而缓存目录 Temp\ 在「清干净重跑 / 换机器 / 别人 clone 后首次构建」时是空的，
# 于是查找必然落空 → 便携版带着 7-Zip 图标出厂，只在警告里说了句就过去了。
# 这正是「便携版图标又没了」反复出现的根因：不是图标注入坏了，是工具压根没到手。
# 下载源与 CI 保持一致（angusj.com 官方 zip），解包后的可执行文件落在
# Temp\echos-build\reshacker\ 下，正好是上面查找链的第一优先级，下次构建直接命中。
if (-not ($rh -and (Test-Path $rh))) {
    $rhDir = Join-Path $tmp 'reshacker'
    try {
        Write-Host '  未找到 ResourceHacker，正在下载（仅首次，约 6MB）…' -ForegroundColor Yellow
        New-Item -ItemType Directory -Force -Path $rhDir | Out-Null
        $rhZip = Join-Path $tmp 'reshacker.zip'
        Invoke-WebRequest 'https://www.angusj.com/resourcehacker/resource_hacker.zip' -OutFile $rhZip
        # 用已定位的 7z 解包；解包目录结构随版本变，按文件名找而不是写死路径
        & $7z x $rhZip "-o$rhDir" -y | Out-Null
        $rh = Get-ChildItem $rhDir -Filter '*.exe' -Recurse -File |
              Where-Object { $_.Name -match 'hacker' } |
              Select-Object -First 1 -ExpandProperty FullName
        if (-not $rh) { throw 'resource_hacker.zip 里没找到 ResourceHacker 可执行文件' }
        Write-Host "  ResourceHacker 就绪: $rh" -ForegroundColor Green
    } catch {
        Write-Warning "  自动下载失败（$($_.Exception.Message)）——便携版将沿用 7-Zip 图标"
        $rh = $null
    }
}
if ($rh -and (Test-Path $rh)) {
    # 4.3a 图标。mask 必须是 ICONGROUP,101 而不是 MAINICON：7zSD 系列 SFX
    # 自带的图标组 id 就是 101，用 MAINICON 只会「新增」一个组而不覆盖它，
    # Windows 按 id 升序取第一个组，便携版就会继续显示 7-Zip 图标。
    # 换 SFX 模块时需重新确认这个 id。
    & $rh -open "$sfx" -save "$sfx" -action addoverwrite `
          -res (Join-Path $root 'installer\logo.ico') -mask 'ICONGROUP,101,' | Out-Null

    # 4.3b 版本资源。不做这步，右键「属性 → 详细信息」显示的是 SFX 模板自带的
    # 7-Zip 信息（1.7.0.3900 / Oleg N. Scherbakov）。
    # 模板里的 LANGUAGE 必须是中性 (0,0)：SFX 原资源就在 000004b0 块里，
    # 若注入成 040904b0（英文），中文系统找不到匹配语言会回退到中性块，
    # 读到的仍然是 7-Zip —— 实测确认过。
    $tpl = Join-Path $root 'installer\portable-version.rc.tpl'
    $rc  = Join-Path $tmp "portable-version-$Version.rc"
    $res = Join-Path $tmp "portable-version-$Version.res"
    $verComma = ($Version -split '\.') -join ','
    if (($Version -split '\.').Count -lt 4) { $verComma = "$verComma,0" }
    $content = (Get-Content -LiteralPath $tpl -Raw -Encoding UTF8) `
        -replace '@VER_DOT@', $Version `
        -replace '@VER_COMMA@', $verComma
    # 写无 BOM 的 UTF-8：带 BOM 时 ResourceHacker 编译可能报错
    [IO.File]::WriteAllText($rc, $content, (New-Object Text.UTF8Encoding $false))
    & $rh -open "$rc" -save "$res" -action compile | Out-Null
    & $rh -open "$sfx" -save "$sfx" -action addoverwrite `
          -res "$res" -mask 'VERSIONINFO,,' | Out-Null
    Write-Host '  已注入 SFX 图标（ICONGROUP,101）与版本资源' -ForegroundColor Green
} else {
    # 刻意说清后果而不是只丢一句「未找到」：这东西缺失不会让构建失败，
    # 产物照常产出，只是图标和版本信息是 7-Zip 的 —— 到时候很容易忘了这茬。
    Write-Warning '未找到 ResourceHacker.exe，便携版将沿用 SFX 自带的资源：'
    Write-Warning '  · 资源管理器 / 任务栏显示 7-Zip 图标，不是 EchOS 云图标'
    Write-Warning '  · 右键「属性 → 详细信息」显示 7-Zip 1.7.0.3900 / Oleg N. Scherbakov'
    Write-Warning "  修法：把 ResourceHacker.exe 放到 $(Join-Path $tmp 'reshacker\ResourceHacker.exe')"
    Write-Warning "  或下次构建时加 -ResourceHacker <完整路径>。安装包（Setup.exe）不受影响。"
}

# 4.4 官方规范拼接：SFX 模块 + 配置 + 归档
$outDir = Join-Path $root 'Output'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = Join-Path $outDir "EchOS-Win-v$Version-x64-Portable.exe"
$fs = [IO.File]::Create($out)
try {
    foreach ($p in @($sfx, (Join-Path $root 'installer\portable-config.txt'), $arc)) {
        $bytes = [IO.File]::ReadAllBytes($p)
        $fs.Write($bytes, 0, $bytes.Length)
    }
} finally { $fs.Close() }

Write-Host "  便携版: $out" -ForegroundColor Green

# 4.5 防伪自检：SFX 里嵌的归档必须和刚构建的 Release 一致。
# 为什么需要：便携版是「SFX 模块 + 配置 + 7z 归档」三段拼接，归档是个独立中间文件。
# 一旦归档是旧的（比如手工分阶段跑构建时传错路径、写到别处去了），拼出来的 exe
# 大小和平时差不多、也能正常安装运行，但装的是上一版代码 —— 不报任何错，极难发现。
# 这里把 SFX 里的 app.so 抽出来和 Release 的逐字节比，对不上就直接构建失败。
$verifyDir = Join-Path $tmp 'verify'
Remove-Item -LiteralPath $verifyDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
& $7z e "$out" "-o$verifyDir" 'data\app.so' -y | Out-Null
$packedApp = Join-Path $verifyDir 'app.so'
if (-not (Test-Path $packedApp)) {
    throw "便携版自检失败：没能从 $out 里抽出 data\app.so"
}
$srcApp = Join-Path $rel 'data\app.so'
$h1 = (Get-FileHash $packedApp -Algorithm MD5).Hash
$h2 = (Get-FileHash $srcApp   -Algorithm MD5).Hash
if ($h1 -ne $h2) { throw "便携版自检失败：包内 app.so($h1) 与 Release($h2) 不一致，归档可能是旧的" }
Write-Host "  便携版自检通过（app.so md5 $h1 与 Release 一致）" -ForegroundColor Green
Remove-Item -LiteralPath $verifyDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '全部完成。' -ForegroundColor Cyan
