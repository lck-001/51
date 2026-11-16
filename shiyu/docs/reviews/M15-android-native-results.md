# M15：Android 原生后台播放有限验收记录

整理日期：2026-11-16；对应既有执行记录为2026-11-13的本地归档。本文只读取源码、构建日志、两份烟测JSON和系统dump，未重新运行设备、音视频、主机窗口或UI自动化。Root独占设备；本轮不控制用户主界面。

## 1. 结论与范围

**有限通过：指定Android x86_64模拟器上的后台音频、系统媒体Pause/Play/Stop及Stop后禁止后台重启的两条烟测链路，已取得实际Android原生服务/MediaSession证据。** 停止后额外电源快照为`Wake Locks: size=0`。

这不是仅凭Dart假Adapter或状态机测试推定后台能力，也不是完整M13矩阵、真实手机、四端或产品发布验收。自然结束、系统进度条定位、页面切换、真正锁屏等尚未完成，不在通过清单。

## 2. 本次候选包和环境

| 项目 | 本记录依据 |
| --- | --- |
| 隔离工程 | `validation/playback-01`，包名`com.shiyu.probe.shiyu_playback_probe` |
| 版本 | `pubspec.yaml`为`0.1.0+1`；本地`build.local.log`记录assembleDebug成功，不是正式签名/上架包 |
| 平台 | Root既有执行环境为Android x86_64/API36模拟器；本次未重新查询设备，未运行真实Android手机 |
| SDK | 本地Flutter3.50.0/Dart3.14.0；Android模板经FlutterExtension采用min24、compile36、target36，服务dump也显示target36 |
| 播放引擎 | 保留media_kit 1.2.6，一个应用持有的Player；原生系统Adapter为audio_service 0.18.19受控本地修订＋audio_session 0.2.4 |
| 输入/隐私 | 既有本地合成英语音频；未用用户真实材料或人声、未接入专业声学服务。本记录不复制音频、系统日志或设备标识进仓库 |

当前源码版本与这次已执行APK应由Root归档时关联最终提交/构建记录。本文没有凭后来任意修改的源码替原烟测补做验收；也没有给未记录的APK哈希或ABI分发范围填造证据。

## 3. 已通过的链路与可复核值

原始证据保存在本地非提交目录`dayline-prototype/planning/playback-v15/`。下表仅摘录与本App相关的状态和值，不包含系统UID、序列号、访问令牌、完整文件路径或原始dump。

### A．播放中退后台→系统暂停→系统恢复→系统停止

`native-smoke.local.json`的`passed=true`，对应原生dump进一步按本App的media-session区块核对：

| 步骤/本地证据前缀 | 本App系统媒体状态 | 本App媒体FGS | 判定边界 |
| --- | --- | --- | --- |
| `background-a` | PLAYING，位置4907ms | true | Root先发Home退后台；这不是锁屏 |
| `background-b` | PLAYING，位置7258ms | true | 后续采样位置继续推进，说明该后台区间仍在播放状态 |
| `system-pause-a` | PAUSED，位置7749ms | true | 硬件媒体Pause命令已进入同一播放链路 |
| `system-pause-b` | PAUSED，位置7749ms | true | 暂停保持，不擅自复播；合法会话暂留FGS供用户恢复 |
| `system-resume` | PLAYING，位置9014ms | true | 硬件媒体Play成功恢复已有合法宿主 |
| `system-stop` | NONE；raw dump仍记9261ms | false | 发送Stop并等待约9秒后，不再持有FGS |
| `after-stop-play` | NONE；raw dump仍记9261ms | false | 停止后再发后台Play，没有重新建立播放或FGS |

这些是系统状态与位置观测，不等于人工听音、扬声器声压或音质证据。两次暂停位置相同只支持该短采样窗口的稳定性，不代表所有后台时长和厂商策略已经覆盖。

### B．回到前台重新播放→后台暂停后Stop

`pause-stop.local.json`的`passed=true`，同样有对应`*-media.local.txt`和`*-service.local.txt`：

| 步骤 | 本App系统媒体状态 | 本App媒体FGS | 结论 |
| --- | --- | --- | --- |
| `replay-foreground` | PLAYING，位置780ms | true | 前台新用户播放可再次建立合法会话 |
| `paused-before-stop` | PAUSED，位置1994ms | true | Pause仍保留后台恢复所需宿主 |
| `paused-stop` | NONE；raw dump保留1994ms | false | 不仅播放中Stop，暂停后Stop也退FGS |
| `paused-stop-no-restart` | NONE；raw dump保留1994ms | false | 随后的后台媒体Play仍不自动复播 |

### C．Stop后电源与元数据抽查

- `after-stop-power.local.txt`记录`Wake Locks: size=0`、`mWakeLockSummary=0x0`，历史中可见audio_service锁的释放；支持采样时没有残留wake lock，不能扩展成长期电量/功耗结论。
- 两份JSON各步骤的`filenameLeaked=false`，并且对应本App媒体dump的描述为通用标题“拾语音频”。支持本次系统元数据未出现被检测的合成文件名；不是已验证所有私有元数据、封面、异常日志和文件路径场景。

**解析限制：** 两个烟测脚本在没有非NONE会话时回退输出`positionMs=0`；因此JSON中的Stop位置0不能证明播放进度被实际清零。本文按raw dump本App区块记录9261ms/1994ms；不使用此0值宣称进度持久化或恢复定位已通过。脚本原本按活动会话筛选，本文另对原始dump中的本App区块作只读核对，未修改或重跑脚本。

## 4. 曾经失败的停止路径与修复边界

前一轮未修订的audio_service停止后出现：MediaSession inactive/NONE、`startRequested=false`，但仍有MediaBrowser绑定且FGS=true；`stop-late-service.local.txt`保留该FGS残留证据。不能把媒体已NONE当作前台服务、通知和wake lock已全部退出。

精确上游0.18.19中，`AudioService.stop()`只有`deactivateMediaSession()`与`stopSelf()`，而`stopForeground`/wake lock释放在其他退出路径或`onDestroy()`中。仍被绑定的服务不保证因stopSelf立即销毁；当`androidStopForegroundOnPause=false`用于支持合法后台Pause→Play时，这一缺口在本次模拟器上暴露。

修订后`stop()`先调用已有`exitForegroundState()`，再走原deactivate/stopSelf：显式Stop释放FGS和wake lock；普通Pause仍由原`exitPlayingState()`及false配置处理，不改成Pause便退宿主。上面两条已过链路覆盖了Pause→后台Play和paused Stop，未仅测试happy path播放中Stop。

Host还按同token去重终态提交，避免host/progress回声重复发Ready/drain/Idle。`_submittedIdleToken`只表示idle已提交，不代表原生已退FGS；最终停止判定仍以上述实际系统dump为据。后台Stop还保留真实引擎idle、native callback/timer drain后再退系统宿主的顺序；不能凭固定等待时间证明任意硬件资源都已物理释放。

## 5. Vendored依赖与可追踪性

本次只在新lab使用`dependency_overrides`指向`../../third_party/audio_service`，lock记录path来源和0.18.19；未将共享pub缓存改成无来源补丁，也未把本地fork称作未改上游包。

- 上游发布归档SHA-256：`95f3267f3449eb5cf71c8fcf1d556f57af1e898e2dc5815fb168d1843653edb7`。
- `third_party/audio_service/UPSTREAM.json`记录 **59个上游runtime/元数据文件**各自原始SHA；本次只读重算：59项均存在，只有`android/src/main/java/com/ryanheise/audioservice/AudioService.java`与原SHA不同。
- 唯一上游变更为`stop()`的两行说明注释和一行`exitForegroundState();`；原LICENSE、README、pubspec及Android/Darwin/Web源码保留。
- 另有自有`UPSTREAM.json`与`SHIYU_PATCH.md`两份追踪文件，所以当前vendor目录实际61个文件；“59”指上游清单，不混作目录总数。
- 原MIT许可完整保留。换上游版本或移除override前，需确认等效停止修复并重跑同一运行矩阵；传递依赖、ABI、签名和发布许可仍各自管理。

## 6. 尚未通过、不得补写为通过的项目

| 项目 | 当前状态/后续证据 |
| --- | --- |
| 自然ended自动退会话 | 未完成。需实际播完并观察真实idle、FGS/wake lock退出及不自动复播 |
| 系统进度条Seek | 未完成。代码/纯状态覆盖不能替代系统拖动后真实音频定位与回写 |
| 页面切换后续播 | 未完成。需验证普通页面退订不销毁应用Player，与Shell退出区分 |
| 真正锁屏/解锁 | 未完成。本次Home只证明后台，不等于锁屏路径 |
| 真实手机与min24附近/厂商省电 | 未完成，仅x86_64模拟器/API36；蓝牙、来电、耳机拔插、其他App焦点及长时间后台另需矩阵 |
| UI/用户交互验收 | 本文没有判定布局、词卡、按钮命中或动画通过；也未验证用户当前主界面 |
| 声学/内容效果 | 未人工听音验音质，未接专业评测；系统PLAYING不证明用户听懂、发音提升或内容准确 |
| 系统强停、杀进程/重启、Back清理完整矩阵 | 未在这两条JSON中完成，不能从单次Stop外推 |
| Apple、Windows | 本记录不授予其他平台通过结论，需分别归档证据 |
| 旧`0.0.3`实机候选 | 用户此前实机路线继续延后；本次新包`0.1.0+1`烟测不能追认旧包，不能声称新包已安装到用户手机 |

## 7. 当前阶段与下一步

当前为M15有限Android原生隔离验证，不是完整产品、人工验收、灰度或上线放行。可将已过两条链路与vendored修复纳入Root本轮提交/归档，原始音频、系统dump、设备标识、工具链、APK和本地receipt保留本地、不进Git。

下一步在用户允许的后台工程边界内继续源码/日志工作；真正锁屏、系统Seek、页面切换、自然结束和用户实机操作由Root统一安排，操作主界面/设备前遵守当次用户授权，不能在本记录整理时顺手重跑。用户当前无需操作。
