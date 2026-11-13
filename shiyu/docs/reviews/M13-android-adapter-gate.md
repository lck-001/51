# M13 Android 原生 Adapter 准入与精确依赖复核

复核日期：2026-11-13（本环境日期）。范围：Android min24 / target36 的有限后台音频隔离实现，保留 media_kit。只读官方包元数据/归档源码、本地缓存和Android文档；未改App代码、pubspec/lock、manifest，未运行设备、音视频或付费服务。官方归档仅下载到内存读取，未解压安装、执行包内代码。

## 1. 结论与准入

**可以进入受限Android Adapter实现与静态/构建验证；不能宣布后台/锁屏/音频焦点已实机通过。** 精确版本环境无声明性冲突，FGS真实反馈与单一焦点路径必须作为实现合同。不能发布假playing启动FGS，也不能把AudioService初始化、MediaSession active或插件支持Android解释为hostReady。

初查项目缓存`dayline-prototype/.toolchains/pub-cache/hosted/pub.dev`和默认LocalAppData缓存：没有audio_service/audio_session两个包；media_kit 1.2.6、media_kit_video 2.0.1、media_kit_libs_android_video 1.3.8已存在。新增依赖需要获准联网解析并更新lock，不能把本次元数据读取当作pub get或构建完成。

## 2. 精确包与工具链证据

直接读取pub.dev精确版本JSON与其archive_url归档；发布时间两者均为2026-06-29。

| 项目 | 实际声明/本地证据 | 本项目判断 |
| --- | --- | --- |
| audio_service **0.18.19** | Dart `^3.6.0`、Flutter `>=3.27.0`；依赖audio_session `>=0.1.25 <0.3.0`；rxdart `>=0.26.0 <0.29.0` | 与精确audio_session 0.2.4范围相容 |
| audio_session **0.2.4** | Dart `^3.6.0`、Flutter `>=3.27.0`；rxdart同范围、meta `^1.3.0` | 不声明Windows实现；本轮只启用Android路径 |
| Android归档 | 两包compileSdk35、Java17；service min19，session min24；各自AndroidManifest均为空 | app min24/compile36可覆盖声明；权限/service/receiver必须由应用显式配置，不能期待插件自动合并加入 |
| 归档构建配置 | service AGP9.0.1；session AGP9.0.1/Kotlin2.3.20，AGP9下不再重复apply Kotlin Android插件 | app当前AGP9.3.1/Kotlin2.4.20、Gradle9.5、Java17未见声明性硬冲突；仍需实际Gradle解算/编译证据 |
| 本地Flutter | `bin/cache/flutter.version.json`为Flutter3.50.0 stable、Dart3.14.0；FlutterExtension默认compile36/min24/target36 | SDK范围满足；不能仅由范围满足宣称全部传递依赖和native ABI可用 |

pubspec建议精确锁定`audio_service: 0.18.19`及`audio_session: 0.2.4`，保留现有media_kit三包版本，不为此次接入同时升级播放器/录制器。新传递依赖以实际解算后的lock差异审阅，不覆盖既有pin去绕过冲突。

本轮另读取两份精确归档的根LICENSE：audio_service 0.18.19与audio_session 0.2.4均为MIT（Ryan Heise及贡献者）。保留版权/许可通知；这不代替新增传递依赖与AndroidX/媒体二进制的各自许可清单。

归档SHA-256：

- audio_service：`95f3267f3449eb5cf71c8fcf1d556f57af1e898e2dc5815fb168d1843653edb7`
- audio_session：`f9e7711a0e24ca8b40f5d7ac374c3c6e55016f3157912badd18199cdbbca5c4d`
- media_kit 1.2.6官方归档：`ae9e79597500c7ad6083a3c7b7b7544ddabfceacce7ae5c9709b0ec16a5d6643`

## 3. 单一焦点所有者：audio_session，不是第二套播放器

保留一个由应用/AudioHandler宿主持有的media_kit Player。UI、系统通知、耳机命令都进入同一Playback Module；AudioHandler回调不能直通Player绕过capture hold、requiresFreshPlay或命令代际。

audio_session由唯一SystemPlayback Adapter调用：配置语音内容（USAGE_MEDIA / CONTENT_TYPE_SPEECH、gain、willPauseWhenDucked），明确只在合法Play激活，在Stop/宿主结束放弃；中断/耳机拔出事件进入core，不由示例代码直接自动play。语音内容临时duck优先暂停而非与其他声音叠读，恢复继续受现有core的多hold和新Play门闩控制。

**不能直接写`PlayerConfiguration(nativePlugin: false)`**：本地缓存和本轮读取的精确media_kit 1.2.6官方归档中，`lib/src/player/platform_player.dart`的PlayerConfiguration没有nativePlugin参数；搜索其Dart/Java/Kotlin也未发现该字段或AudioFocus请求。Java libs插件只负责加载mpv与application context，不能从其他版本/包的文档借来不存在的开关。

本次检查未发现media_kit Dart/Java自身显式requestAudioFocus；这不构成对所有libmpv内部二进制行为的审计。不能宣称已证明它绝无隐含焦点行为。隔离实现先采用audio_session唯一路径，构建/运行日志与后续焦点竞争用例核验实际引擎，发现双重所有者时停接入复核，不靠添加第二套AudioManager监听修补。

## 4. Android36合法启动与真实状态时序

Android官方规定target35+请求焦点时必须是top app或运行FGS；在同一已前台的用户点击Play中，可以先获得焦点，无需先伪造FGS。推荐路径：

1. 当前Activity真正前台，明确UI Play；core核验素材/代际、全部输入/预览资源确认closed、无阻断hold；仅此时允许新播放意图。
2. audio_session请求焦点并检查返回true；拒绝/异常则不调用engine.play，不发playing。每次await前后重验foreground/epoch和采集账本，不能依点击时的旧快照继续。
3. engine.play后等待真实引擎回调；只在实际playing时向audio_service发布playing状态，提供通用MediaItem和Play/Pause/Seek/Stop。命令accepted不等于已出声。
4. audio_service执行native进入FGS；观察成功/失败及真实宿主。状态发布是异步的，不能在`playbackState.add`后立刻写hostReady=true。
5. 切后台若FGS尚未确认、已消失或观测unknown，core保守暂停并报告后台宿主未就绪；不能在后台靠反复发布playing重新启动FGS。若合法现存宿主确认，则允许持续听音及受控系统命令。

精确archive源码事实：

- `AudioService.java` 503起`setState`，559–562只有false→true触发`enterPlayingState`；705–728调用`startForegroundService`、激活MediaSession、acquireWakeLock、`startForeground`。因此init/媒体会话已连接不是FGS确认。
- 同文件715–718仅在`androidStopForegroundOnPause=true`时离开前台；`stop()` 355–358去激活并stopSelf，`onDestroy` 361–384清会话/FGS/wakelock且instance=null。
- `lib/audio_service.dart` 1126–1139观察播放状态异步setState，异常进入`AudioService.asyncError`（982–985），不是同步由`playbackState.add`抛回。实现必须订阅asyncError，失败回core置宿主不可用、暂停/释放焦点，不能漏掉。
- Java未发现独立AudioFocus请求；audio_session实际经AndroidAudioManager请求/放弃焦点。不要再写原生第二套requestAudioFocus。

可将`androidStopForegroundOnPause:false`用于**已由前台合法建立的本次会话**，支持后台暂停后继续；`androidResumeOnClick:false`避免已Stop后仍通过旧媒体恢复入口复播。false还意味着插件暂停时可能保留wakeLock，不能无期限拿FGS充当保活。明确Stop、应用主动退出/任务移除、会话结束或后续批准的空闲退出策略应释放，并使后台恢复资格失效；退出后新的Play需回到合法前台重新建立。

BaseAudioHandler默认`onTaskRemoved`为空；必须将本实验约定的任务移除/明确退出映射为core Stop，而不是假设插件默认清理。页面dispose与系统宿主结束仍不同，不在普通页面退出时销毁Player。

## 5. 狭窄nativeHostReady观测与能力合同

建议窄原生查询只观察本App的AudioService，不启动服务、不请求焦点、不枚举用户其他应用、不查询音视频内容。可在隔离probe内使用`ActivityManager.getRunningServices`匹配本包的`com.ryanheise.audioservice.AudioService`、本App UID/有效进程且`foreground=true`作为一次正向FGS观测；缺失、异常或不可用返回notRunning/unknown及有限原因，绝不默认true。

该API在26废弃，但官方注明兼容返回调用者自己的services，定位debug/service-management；本次隔离观测与该用途相符。它是瞬时证据，不是保证存活，不能当未来生产永久依赖承诺。不得请求DUMP、QUERY_ALL_PACKAGES或访问其他App信息。若此路径无法可靠观测，保持hostReady unknown/false并仅前台播放，再评审显式native宿主确认方式；不能退而使用Service.instance非空、MediaSession active或config已加载造ready。

观测回调关联当前host/session generation，Stop、native销毁、通道断开、asyncError、账号/素材会话切换立即失效；后台显式Play前做新鲜核查，不能使用很久以前的true。`capabilities.available`只表示Adapter配置/初始化可用，`hostReady`只表示现存合法宿主观察，`deviceVerified`仍为false；三者不得混为一值。前台建立过程中可available=true/hostReady=false，并不得因此阻止合法前台请求焦点。

## 6. 具体Manifest与Activity方案

现有manifest保留RECORD_AUDIO、CAMERA前台采集用途及READ/WRITE_EXTERNAL_STORAGE移除项；不因后台听音新增采集权限。只增：

```xml
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
<!-- application内：现有.MainActivity与启动intent保持 -->
<service
    android:name="com.ryanheise.audioservice.AudioService"
    android:exported="true"
    android:foregroundServiceType="mediaPlayback">
  <intent-filter>
    <action android:name="android.media.browse.MediaBrowserService" />
  </intent-filter>
</service>
<receiver
    android:name="com.ryanheise.audioservice.MediaButtonReceiver"
    android:exported="true">
  <intent-filter>
    <action android:name="android.intent.action.MEDIA_BUTTON" />
  </intent-filter>
</receiver>
```

WAKE_LOCK源于该精确插件的PARTIAL_WAKE_LOCK，不是要求常亮屏幕。媒体通知与正常业务提醒权限分开：**不增POST_NOTIFICATIONS**，不借媒体会话通知豁免发运营/意见通知；不增microphone/camera FGS、BOOT_COMPLETED、广泛存储、忽略电池优化、全局包查询或传感器后台路径。

保留MainActivity现有类名/namespace，使其继承`AudioServiceActivity`；若后续插件确需FragmentActivity则用`AudioServiceFragmentActivity`。两类都返回同一AudioServicePlugin管理的FlutterEngine。当前MainActivity仅继承FlutterActivity，直接只加service会触发wrongEngineDetected或绑定错误。若必须保留自有父类，要准确实现插件文档所需engine提供/缓存绑定，而不是另建一个FlutterEngine；本轮首选简单继承并在既有configureFlutterEngine中注册窄观测通道，保留super调用。

插件的MediaBrowser/receiver exported是系统控制接入，不是任意素材入口。AudioHandler拒绝外部提供的任意URI、路径、未知MediaId、prepare/playFromSearch等未支持命令；只接受当前受权素材的Play/Pause/Seek/Stop，列表可为空。标题默认“拾语音频”、不设私人artUri、正文、路径或签名URL；不开远端封面自动获取。

## 7. 静态/构建门禁与回滚

进入有限实现后，由root核验：精确lock与hash；merged manifest仅期望新增三权限和mediaPlayback service/MEDIA_BUTTON receiver，插件无隐含开机/存储/通知权限；MainActivity同引擎绑定；所有异步错误映射；Android APK构建、权限清单、依赖差异及本地receipt不入Git。两包compile35仍需Android35工具链/依赖解算，本机platforms/android-35与36已存在，不代表构建已经通过。

系统Adapter必须可注入不可用/拒焦点/宿主未知/异步FGS错误，验证core不假报ready；采集资源unknown期间系统Play拒绝，不排成采集结束后的自动播放。原生ABI、厂商省电、真正后台/锁屏、中断与通知展示仍待Android实机，当前不运行。

回滚成对移除新增两包/相关lock、service/receiver/三权限和Activity父类/观测通道；先停止播放并释放FGS/焦点，保留素材/进度。不可用时退到明确仅前台播放，不回退captureEpoch、unknown账本或requiresFreshPlay门闩；不得删除lifecycle安全分支后宣称后台支持成功。

当前真正阻碍：包未解析缓存/构建，宿主尚无实际确认接口，media_kit与Android实际焦点/宿主联动未运行验证。不是已证实的不兼容；可按本稿做隔离实现，不需要用户挑插件或manifest参数。用户当前无需操作设备；后续由团队依M13矩阵组织Android设备验收，iPhone/Mac/Windows分别取证。

## 证据入口

- 精确元数据：`https://pub.dev/api/packages/audio_service/versions/0.18.19`、`https://pub.dev/api/packages/audio_session/versions/0.2.4`；本轮只读JSON与其官方归档，并校验可见版本/环境/Android源码。
- 固定tag service源码：`https://github.com/ryanheise/audio_service/tree/audio_service-v0.18.19/audio_service`；发布归档为本稿行号依据。
- 包功能/manifest说明：`https://pub.dev/packages/audio_service/versions/0.18.19`、`https://pub.dev/packages/audio_session/versions/0.2.4`。
- Android焦点规则：`https://developer.android.com/media/optimize/audio-focus`。
- FGS类型：`https://developer.android.com/develop/background-work/services/fgs/service-types`。
- 媒体通知豁免：`https://developer.android.com/develop/ui/views/notifications/notification-permission`。
- 自身service观测：`https://developer.android.com/reference/android/app/ActivityManager#getRunningServices(int)`、`https://developer.android.com/reference/android/app/ActivityManager.RunningServiceInfo#foreground`。
- 本机：`dayline-prototype/.toolchains/flutter/bin/cache/flutter.version.json`、FlutterExtension.kt、工程android/settings.gradle.kts、gradle-wrapper.properties，以及缓存media_kit 1.2.6/Android libs 1.3.8源码。缓存/工具链/receipt不提交仓库。
