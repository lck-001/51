# M13：后台与锁屏播放架构评审

日期：2026-11-12。结论：采纳独立播放 Module 与平台 Adapter 的设计，保留 media_kit；平台接入进入隔离验证候选，尚未确认四端后台能力。本次只交方案，不修改运行代码、依赖、权限、系统或设备。

## 当前问题与本次范围

`validation/media-01/lib/main.dart` 在 paused/hidden/detached 时统一停止采集并暂停 Player，页面 dispose 又销毁 Player。它能保护前台采集，却不能满足锁屏继续听音；简单删除 pause 也没有解决系统会话、焦点、执行宿主与中断恢复。

本次只处理用户主动开始的一段音频：切换页面、切后台、锁屏后延续播放，支持系统播放/暂停/定位。视频默认切后台暂停；视频转纯音频、画中画、自动启动、任务栏托盘常驻与进程被杀后自动复播均不纳入此次接入。

## 小 Interface 与真实 Seam

**Playback Module** 隐藏命令排序、播放意图、焦点、中断、系统状态发布与引擎回调，形成 deep Module。UI 不学习 Android/iOS 分支，也不直接操作 Player；系统控制与 UI 经过同一外部 Seam。保留一个 media_kit Player，不另造一个后台播放器。

```dart
// 设计契约，不是本轮实现。
abstract interface class Playback {
  Stream<PlaybackSnapshot> get snapshots;
  Future<CommandResult> dispatch(PlaybackCommand command);
}
// 命令：Open(素材版本引用), Play, Pause, Seek, SetRate, Stop。
// 不对外暴露 MediaSession、AVAudioSession、Player 或 raw 文件路径。
```

Interface 的调用约束：Open 默认加载不自动播放；Play 必须来自明确的 UI/系统媒体操作或受限的中断恢复。命令返回 accepted/rejected/unsupported，accepted 不表示已经出声，实际结果由 snapshot 确认。Seek 必须可定位且位置在有效时长内；缓冲不发布为播放完成。顺序处理命令，对连续 Seek 合并保留末次；用 itemGeneration/commandEpoch 丢弃旧素材、旧会话和旧恢复回调。

| snapshot 信息 | 含义与约束 |
| --- | --- |
| intent：playing/paused/stopped | 用户希望怎样；系统临时暂停不能悄悄改成用户暂停 |
| actual：idle/loading/buffering/playing/paused/ended/failed | 引擎观察值；点击播放不能立刻伪报playing；播放本身不等于完成学习 |
| pauseCauses：一组原因 | user、focusTransient、focusLoss、routeDisconnected、capture、backgroundUnsupported、videoPolicy、systemSuspended、error；可同时存在，不能用最后一个原因覆盖全部 |
| itemRevision、position、duration、rate、error | 固定素材版本、实际进度与可解释错误；UI与系统媒体面板共享该状态 |
| capabilities | backgroundAudio、systemControls、seek、rate等按平台/会话返回；未验证或不可用时明确降级 |

内部 Seam 有实际变化来源：**Engine Adapter** 把 media_kit 的事件和命令归一；**SystemPlayback Adapter** 对接 Android 会话/FGS、Apple系统控制和Windows SMTC，各自发布能力与中断事件。平台命令只流入 Module，snapshot只单向发布到平台，避免系统暂停 → 回写暂停 → 再回调的循环。音频焦点/会话配置必须只有一个所有者，先核对现有引擎与插件行为，不能两套监听重复暂停/恢复。

播放对象由应用级/系统后台宿主持有，页面只订阅与退订；页面退出不 dispose Player。系统真正结束会话时才释放；Activity detached 与后台宿主结束分开处理。持久化仅保存素材引用和位置，重启恢复为暂停；不存一次性的playing意图来触发自动复播。

**Capture Module** 继续拥有麦克风/相机、显式授权和前台生命周期。应用内部音频使用协调器先暂停播放，再允许用户发起采集；后台时停止并保存采集、释放预览，不把此流程变成播放 Module 的整体 shutdown。许可对话框引起的 inactive 不当作真正切后台；任何捕获都不因恢复焦点或返回前台自动开始。结合[独立QA评审](M13-qa.md)，以下三项为必须满足的Interface合同。

### 采集与异常清理合同

1. **新Play门闩**：用户一发起录音、录像或可能占用输入的预览，就同步设 `intent=paused`、递增 `commandEpoch`、设 `requiresFreshPlay=true` 并撤销原焦点恢复资格，再等待暂停/权限/初始化。成功、失败、取消、拒权、采集结束或capture hold消失均不能清除此门闩；清除只发生于全部采集/预览资源确认closed后收到新的明确UI/系统媒体Play。焦点恢复、返回前台与普通状态对账均不算新Play。这样旧intent不会在hold移除后自行播放。
2. **按资源而非录制布尔互斥**：Capture维护录音、录像、预览及pending初始化的资源账本，状态为starting/active/stopping/closed/unknown，并保留所属captureEpoch和handle。预览即使未录像也可能占用音频输入；任一相关资源不是确认closed（包括unknown）时，系统和UI的Play均拒绝，不排成稍后自动执行。只有引擎确认停止播放后才允许采集启动；拒权后资源已确认closed时可接受新的Play，不循环索权。
3. **同步失效，独立收敛**：真正后台/退出事件到达时，立即同步更新foreground、递增captureEpoch并禁止新采集，不能等长初始化队列执行到尾才失效。每个start/initialize在await前后都核对foreground+captureEpoch+所属handle；过期成功必须补偿停止/释放，迟到handle也要入账清理，不能丢掉回调。原生调用若不支持安全并发取消，不盲目同时调用stop/dispose；立即标失效，在Adapter允许的最早时机补偿，超时记unknown而非假closed。

清理会为stop、可用产物保存、预览dispose、播放器pause分别记录attempt及结果；一个异常不能跳过其他资源的清理。保存依赖stop返回有效产物时，缺少产物应记“无法保存/待恢复”，不能伪报成功；同一原生handle的操作遵守其并发合同，其他资源的pause/dispose仍独立尝试。每一步有有界等待和可解释错误，超时/抛错保留未确认释放的handle及unknown账目，不因引用置null、队列结束、dispose已调用就认定硬件关闭。忙碌期间系统主动停止事件也须记录并幂等归并，不丢弃。

| 最低状态事件 | 同步决定 | 异步完成时的合同 |
| --- | --- | --- |
| Capture/Preview requested | paused、epoch++、新Play门闩、capture hold | 播放暂停确认后才可请求采集；失败/拒权保留门闩 |
| 真正后台或退出 | foreground=false、captureEpoch++、撤销pending启动资格 | 独立attempt清理；返回前台不恢复旧采集 |
| Initialize/Start succeeded late | 只匹配所属handle与epoch，不覆盖新会话 | 过期则补偿释放；失败/超时留unknown，禁止播放和再次采集 |
| Stop/Dispose failed或超时 | 保留handle/unknown与阻塞原因 | 其他清理继续；有明确释放证据才可closed |
| Capture/Preview all closed | 可移除对应hold，不撤销新Play门闩 | 等待新的明确Play；旧焦点恢复事件失效 |
| 明确Play且资源全部closed | 按当前epoch接受；清除门闩并设置playing意图 | 焦点/宿主许可及引擎状态仍须确认；不因accepted假报已播放 |

## 状态与恢复决定

| 事件 | 播放处理 | 恢复条件 |
| --- | --- | --- |
| 音频播放中切后台/锁屏 | 平台宿主已就绪则继续；未就绪则暂停并报告backgroundUnsupported | 不用恢复到前台事件自动开播 |
| UI或系统面板暂停/停止 | 改intent，暂停/停止；Stop清理会话和焦点 | 必须新的明确Play |
| 临时焦点/系统中断 | 保留原intent，添加独立hold，暂停语音内容 | 仅原先实际播放、同素材同epoch、系统允许恢复、全部hold消失时可恢复；用户中途暂停优先 |
| 永久焦点失去、耳机断开、采集结束 | 暂停并设置需用户确认的原因 | 不自动从扬声器出声；耳机重新连接也不自动复播 |
| 系统媒体会话/引擎错误 | 停止出声，真实发布错误和位置，必要时释放宿主 | 手动重试，不能被下一次普通lifecycle清掉错误 |
| 睡眠、系统终止/强停、用户退出应用 | 保存已有检查点，尽力清理；不承诺异步回调一定运行 | 唤醒/重启默认暂停；不绕过系统限制 |

## 四端接入候选与能力差异

| 平台 | 建议 Adapter | 必须验证与限制 |
| --- | --- | --- |
| Android，target36/min24 | 首选隔离验证 audio_service 0.18.19 的 AudioHandler持有现有media_kit，管理MediaSession、媒体通知与mediaPlayback FGS；audio_session 0.2.4仅作焦点/中断候选 | 插件声明支持不等于本工程通过；确认Flutter后台宿主、media_kit实例/纹理与Activity解绑、进程存活、焦点唯一所有者；不直接把media_kit Player传入Media3 Player接口 |
| iPhone/iOS | 同一Playback Interface；audio_service候选承接系统命令；AVAudioSession采用playback/适合语音的模式，配置Background Audio；用MPNowPlayingInfoCenter/MPRemoteCommandCenter | 仅播放激活时占用会话；处理拒绝激活、中断、耳机断开及录音插件改写全局会话；真机锁屏、静音开关、蓝牙待验证 |
| 原生macOS | media_kit桌面进程持有播放；MPNowPlayingInfoCenter/MPRemoteCommandCenter接系统控制，优先验证audio_service的macOS实现 | **不照搬AVAudioSession**：Apple availability列iOS/MacCatalyst而未列原生macOS；进程存活与电脑睡眠分开，锁屏控件不可因包支持macOS就宣称可用 |
| Windows | 保留media_kit，使用现有C++ runner技术栈实现窄SMTC Adapter，GetForWindow关联顶层窗口、发布状态并收命令 | media_kit不是Windows MediaPlayer，不能获得其自动SMTC集成；最小化/锁屏可继续须实测，退出/睡眠不承诺；不引入托盘守护进程 |

依据：[audio_service平台/功能表及任意音频引擎接入说明](https://pub.dev/packages/audio_service)、[audio_session全局会话与中断说明](https://pub.dev/packages/audio_session)、[Apple AVAudioSession及availability](https://developer.apple.com/documentation/avfaudio/avaudiosession.md)、[Apple远程控制](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter.md)、[Apple Now Playing](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter.md)、[Windows SMTC与自动集成条件](https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/integrate-with-systemmediatransportcontrols)、[Win32 GetForWindow](https://learn.microsoft.com/en-us/windows/win32/api/systemmediatransportcontrolsinterop/nf-systemmediatransportcontrolsinterop-isystemmediatransportcontrolsinterop-getforwindow)。

audio_service当前未声明Windows支持，其功能表也没有标macOS锁屏控制；不能称其一包装齐四端。Windows现成备选[smtc_windows 1.1.0](https://pub.dev/packages/smtc_windows)仅声明Windows并要求Rust工具链，本轮不采纳额外Rust安装。若移动候选与media_kit冲突，再评估原生SystemPlayback Adapter；Android原生Media3桥需要满足其Player Interface，不能仅加一个通知代替后台宿主。此后备方案需另估工作量，不默认换ExoPlayer。

## Android36权限与媒体通知专项

target36受target35+音频焦点规则约束：请求焦点时须为顶层应用或正在运行FGS。用户在前台点击Play时建立合法宿主/会话并请求焦点；失败保持暂停，不等进入后台才偷偷启动。Android后台播放候选需要在实现评审中明确声明FOREGROUND_SERVICE、FOREGROUND_SERVICE_MEDIA_PLAYBACK及mediaPlayback类型；这些是拟议manifest变更，**本轮未添加**。不新增microphone/camera FGS、不加开机播放接收器或广泛存储权限。[焦点规则](https://developer.android.com/media/optimize/audio-focus)、[媒体FGS类型](https://developer.android.com/develop/background-work/services/fgs/service-types)、[官方后台宿主说明](https://developer.android.com/media/media3/session/background-playback)

系统媒体通知用于显示当前播放与控制，和产品“投诉/意见仅应用内提醒”是两项独立能力。Android官方说明FGS启动不要求POST_NOTIFICATIONS，但仍须通知；媒体会话通知属于通知权限变更的豁免范围。因此不为后台听音顺带申请POST_NOTIFICATIONS，也不把媒体豁免用于投诉、运营或学习提醒推送。适配后核查合并manifest及实际系统展示，不凭豁免推定所有厂商行为一致。[通知权限与媒体会话豁免](https://developer.android.com/develop/ui/compose/notifications/notification-permission)

系统面板默认只发布通用标题“拾语音频”、进度和控制；不用私人文件名、正文、录制缩略图或来源URL作为元数据。Apple Now Playing可能参与系统建议，按可用能力选择排除建议；不能据此把私有素材视为共享。外部控制器只获得允许的播放命令与不透明素材标识，不能任意读取本地文件或开启采集。

## 验证准入、风险与回滚

先验证一个音频、Play/Pause/Seek/Stop的最小闭环，保留现有采集手工门槛；不借本次改整App。以相同Interface验证用户暂停压过焦点恢复、多个hold、旧素材回调、捕获期间外部Play被拒绝、页面退出不销毁会话，随后才接系统Adapter。快照订阅/本地进度检查点可复用，当前_background开关与统一lifecycle pause不可直接沿用。

| 真机验收 | 通过条件 |
| --- | --- |
| Android前台→后台→锁屏持续播放、通知/耳机暂停定位 | target36实际设备可持续播放与准确回写；焦点拒绝可解释，系统停止后无假播放/自启；另测min24附近与厂商电池策略，未覆盖版本标待验 |
| 双平台中断、耳机拔插、切换其他音频应用 | 不争抢、不突然外放；期间用户暂停后绝不自动恢复；iOS依据系统恢复建议与部署版本处理通知，不假设media_kit拥有AVPlayer的自动行为 |
| 录音/录像→后台→前台、捕获时系统面板Play | 摄像头/麦克风按前台规则释放，不自动重开；播放互斥；录制保存结果按真实状态反馈 |
| Windows/macOS最小化、锁屏、系统媒体键、睡眠唤醒 | 页面与系统状态一致；实际睡眠/退出与锁屏区分；不以Windows结果替代Mac/iPhone验收 |
| 终止会话、重启与错误回退 | 残留系统控件清理、焦点归还、进度可恢复为暂停，无重复播放器、僵尸FGS或私有元数据泄漏 |

主要风险是插件后台宿主与media_kit资源生命周期、音频会话竞争、厂商省电、不同OS控制能力和额外依赖/manifest变化。未通过的平台使用明确的“仅前台播放”能力；不能靠常亮屏幕/无限wakelock伪装后台成功。

回滚按平台关闭后台能力，先停播并释放会话/FGS，再回到前台播放Adapter；进度与素材保留、捕获策略不变。回滚也保留requiresFreshPlay、captureEpoch和unknown资源账本，不能以切换Adapter/清空引用解除采集互斥或重新播放；释放失败明确报告，延迟重试只做清理不做重启。若新增插件/manifest被撤回，提交成对回退lockfile与配置，不能留下后台权限和启动路径。所有能力在通过原生实机验收前标“待验证”，本评审不是发布批准。

下一步：产品/架构确认本Interface与四端差异后，立项最小Android后台音频隔离验证，再验证Windows SMTC；iPhone/macOS继续在范围内并安排设备验收。本轮无需用户选择技术参数或操作设备。
