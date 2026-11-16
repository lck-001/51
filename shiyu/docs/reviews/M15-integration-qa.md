# M15：播放集成最终只读QA

日期：2026-11-16。审查对象为`packages/playback_core`、`validation/playback-01`及受控`third_party/audio_service`。本轮只读源码、上游追踪、已有日志/receipt与既有Android验收记录；没有运行测试、浏览器、UI、鼠标键盘、ADB或任何设备/麦克风。本报告不复制原始dump、设备标识、完整素材路径或私有音频入Git。

只读核对时仓库HEAD为`24311f4`。Root确认的Core52/52与本地`core-final.local.log`末行`RESULT passed=52 failed=0 total=52`一致；这是已有纯Core回归结果，不是本轮重跑，更不等于52个原生/真机用例通过。

## 1. 结论

关闭门闩、普通导入/debug bootstrap的epoch保护、通用系统元数据、不伪造playing及native release/drain的边界在代码中表达清楚。已执行的Android两条烟测有原生服务/MediaSession证据，不是只凭假Adapter推定。

本轮指出`_leave()`过去依赖host.close发Stop的跨Adapter复用风险；经Root和本审查进一步核对，**当前PopScope仅在Android调用`_leave`，Android factory固定使用AndroidAudioHost；Windows实际走另一个已显式Stop的WM_CLOSE链路。** 因此不能把该复用风险说成当前Windows可触发故障。Root已在工作树最小补入显式Stop，本审查只读复核到该行及后续真实idle/release等待仍保留，未执行分支。未发现阻碍本轮有限集成归档的新增已证可达故障；完整原生矩阵仍未通过。

当前可保留Android已证有限结果和WindowsOpen-only修复结果；不据此放行完整四端播放、窗口退出、硬件释放、人工验收、灰度或上线。

## 2. 本轮能从代码证明的事项

### A．同步关闭门闩与输入epoch

- `windows_playback_host.dart::_closeOwnWindow`在第一次异步Stop/释放前同步设置`_windowClosing=true`并调用Root的`onClosingChanged(true)`；`main.dart::_windowClosing`递增`_inputEpoch`并锁住`_leaving`。
- 普通`_import()`入口拒绝leaving/importing，文件选择完成后重新验证mounted、leaving及原inputEpoch；晚到选择不能Open新材料。
- `_bootstrapSynthetic()`既有入口检查，又在导入完成和Open返回后分别检查epoch/门闩，避免关闭期间debug自动Play。合成fixture与silent参数仅在debug+Windows启用，静默只作用本Player，不改系统音量。
- `_command`和UI可用条件均有leaving保护；关闭取消只有收到相同native ticket的`cancelled=true`才恢复，未确认取消保持门闩。关闭开始/取消均变化epoch，因此旧导入不会在取消后重新获得准入。
- 原生Windows `closeReady`验证pending ticket和own HWND后才提交WM_CLOSE；Dart在Stop、release、retire后再核对scope/终态，不把普通异步返回当原生已关闭。

这些属于静态机制证明。本轮未运行“文件选择器悬挂/关闭取消/晚到debug自动Play”竞态，也未从WindowsOpen-only receipt补写这些用例已原生通过。

### B．系统元数据与playing事实

- Android发布`MediaItem`使用通用标题“拾语音频”和不含原件名的代际ID；Windows native清空原DisplayUpdater字段后写“拾语音频/拾语”，不取材料标题、文件路径或私人正文。
- `MediaKitEngine::_sample`要求当前scope、前后实际源匹配；Windows路径别名可通过OS文件identity证明，而非只比较文件名/时长。playing还要求原生pause/core-idle/cache/eof/seeking等事实组合，Open并不直接设置playing。
- Android只有实际playing且合法既有宿主或明确前台启动资格满足才发布playing=true；不为留FGS伪造playing，draining阶段发布ready+playing=false。Windows依据engineAvailable和actual发布Changing/Paused/Playing等状态，不用“用户想播放”替代事实。

通用元数据的源码检查不等于所有异常日志/封面/路径泄漏检查均通过；现有Androidreceipt仅有针对本次合成文件名的检测。

### C．release/drain真实边界

- `releaseNative(expected)`在串行seam中要求当前token、已stopped且stopConfirmed，处理所捕获的Player实例；新命令排在其后，旧release不应处置后来新建Player。
- `_native`到时标记unknown/不可用，但仍等待原Future，不因超时提前释放串行队列。Host15秒timeout同样不是底层取消成功证据。
- `_disposeAndDrain`保留固定media_kit 1.2.6下dispose后六秒Dart timer drain，源码明确其针对上游未await的五秒销毁回调。**这是固定版本兼容等待，不是公共原生销毁完成Future，不保证硬件资源全部释放，也不能保证挂起/强杀下完成。** 换media_kit版本必须重审。
- Android后台终态在真实engine idle后先release/drain，再退系统宿主；idle提交按token去重，不能将“已提交idle”当OS FGS已退。

## 3. 退出责任复核与最小防御补充

位置：`validation/playback-01/lib/main.dart::_leave`，以及`windows_playback_host.dart::close`、`foreground_host.dart::close`。

最初指出的潜在复用路径为：

1. SMTC不支持/失效，或使用Foreground fallback，`backgroundHostReady()`返回false；播放仍可在前台处于playing/paused。
2. `_leave`锁住UI后先调用`host.close()`。
3. Windows close只retire系统会话并关闭回调/事件流，Foreground close只关闭事件流；二者不向controller dispatch Stop。
4. `_leave`继而等待`intent=stopped && actual=idle && engineAvailable`；没有Stop请求，正常Pause事实也不满足，可能15秒后失败，且leaving保持true。

**可达性校正：** `main.dart`的`PopScope.canPop=!Platform.isAndroid`，其回调只在`!didPop && Platform.isAndroid`时调用`_leave`。当前main factory的Android分支固定创建AndroidAudioHost，而该host.close内部已有Stop/终态等待。Windows窗口退出实际通过原生WM_CLOSE ticket→`WindowsPlaybackHost::_closeOwnWindow`，已明确Stop、确认idle和release后才closeReady。因此本节不是当前Windows实际退出故障，不将它列为可达P0，也不借潜在路径否定既有Android证据。

Root随后将`await widget.playback.dispatch(const Stop());`放在`host.close()`之前，直接dispatch而不经过已被leaving锁住的UI `_command`。本审查再次只读看到该修改，后续stopped/idle/engineAvailable判断、真实release和失败保持门闩均保留。其作用是让退出责任更明确、避免未来复用Foreground Adapter时依赖隐含副作用；当前未做该分支运行回归，不能写为原生已测。改动由Root完成，本审查没有修改实现。

## 4. 已有执行证据与边界

| 证据 | 已记录支持 | 不支持外推 |
| --- | --- | --- |
| `native-smoke.local.json` | Android后台短区间位置4907→7258ms；Pause两次7749ms；恢复PLAYING；Stop与后续后台Play不再FGS/PLAYING | Home不是锁屏；系统状态不是人工听音；不证明真机/OEM/蓝牙/长后台 |
| `pause-stop.local.json` | 前台新播→后台Pause→Stop→后台Play不重启宿主 | 不证明自然结束/Seek/系统强杀或所有生命周期 |
| `M15-android-native-results.md` | 已按本App raw dump复核；注明Stop后raw仍留9261/1994ms、wake lock采样为0 | 脚本无active会话时JSON位置0是fallback，不能当清零/进度保存证据；本审查未重跑设备 |
| `windows-open-fixed.local.json` | 合成Open-only、silent、未请求Play；duration约92.894秒、position0、native pause=true、file identity前后均真、无加载错误 | 不证明可听播放、SMTC按钮、Windows窗口关闭竞态/睡眠/锁屏/硬件释放；不能把静默加载样本标为播放验收 |
| `core-final.local.log` | 已有Core模型回归52/52 | 不是Android或Windows原生52/52，不追认历史51个假Adapter案例为设备通过 |

烟测脚本原本对整份media-session输出取活动项，存在环境中其他活动会话干扰的解析限制；既有Android验收文已说明另按本App raw区块核对。后续自动化建议限定包的区块后再断言，不能只信`passed=true`或JSON的NONE位置0。

## 5. 受控上游补丁核对

只读重算`UPSTREAM.json`清单各文件SHA，只有`android/src/main/java/com/ryanheise/audioservice/AudioService.java`与记录的上游SHA不同，符合`SHIYU_PATCH.md`“只改一个上游文件”的声明；原MIT许可保留。本文没有访问上游网络归档，因此published archive hash只是追踪记录，不声称本轮重新下载核验。

补丁将既有`exitForegroundState()`放在显式Stop的deactivate/stopSelf前，针对仍有MediaBrowser绑定时stopSelf未即销毁而残留FGS的问题；普通Pause的false配置保持。该补丁不是媒体引擎、不是伪播放、不是Apple/Web行为变更，也不是正式发布批准。移除path override前要确认上游等效修复并重跑相同矩阵。

## 6. 下一步与阶段

第3节复用风险已由Root最小防御补充，当前只读复核，不宣称该分支已执行。后续把关闭/import竞态、窗口关闭ticket和原生drain结果纳入有限验证。未证的自然ended、真正锁屏、系统Seek、页面切换、系统强杀、真机/OEM、Apple等沿既有M15矩阵保留未测，不扩充通过清单。

当前阶段：M15有限播放集成审查。下一建议动作：Root将最小补充关联最终提交，并按当前授权安排有限回归/剩余矩阵；需要用户当前操作：无。本轮没有控制主界面、请求设备权限或改动源码。
