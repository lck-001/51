# M18：学习界面与原生组装验证

2026-11-18。承接 v0.13 和 M16/M17；按独立 QA 与架构复审分别验收。当前仍为工程候选，未进入人工验收、灰度或正式发布。

## 已通过并入库的学习主流程

学习界面、运行时与版本化播放协调已提交至功能分支，提交 `736dab1`。未合并默认分支。

| 层级 | 实际结果 | 证据范围 |
| --- | --- | --- |
| `learning_playback` | 22/22；分析无问题 | 真实临时文件、缓存校验、跨进程恢复及受控 Engine/System |
| `client_shell` | 8/8；分析无问题 | 真实文件存储、无窗口 Widget、阅读布局及逐句操作 |
| `client_runtime` | 9/9；分析无问题 | 实际 Shell 回调、版本/token 隔离、真实进度回读；受控 Engine/System |

独立复核曾拒绝放行并通过红绿测试推动以下修复：

1. 上/下一句和练习原先跟随查词焦点，实际播放到后续句时仍跳到错误句。现以实际播放位置为主；查词与未提交的进度预览不改变播放导航。句间间隙沿用前句，精确下一句起点进入下一句。
2. Stop 后保存开关未恢复，后续播放进度丢失。现保护原续学位置，只有确认的新播放或手动定位才恢复写入，Stop 的零位置不覆盖进度。
3. 原生 Stop 报告 idle，而受控 Adapter 可报告 paused，旧准入错误拒绝 stopped-idle 重播。现仅允许健康同会话、已停止 idle 状态的显式 Play；任意 idle 和未加载 Seek 仍拒绝。命令接受不等于实际播放。

以上不证明原生声音、解码、OS 生命周期、真实英语生成或专业发音评分已通过。

## 原生客户端组装

独立入口 `validation/playback-01/lib/client_main.dart` 复用现有存储、私有缓存、MediaKitEngine、平台 Host、协调器和运行时。保留原探针入口；默认本机私有空库，不创建伪造学习数据或自动播放。该工程仍沿用探针包身份，并非正式发行版。

首轮 Android x64 调试构建实际成功（Gradle 149.2 秒），构建期间原生关闭实现仍在评审修订，未将该包作为最终结果。修订后的客户端已重新构建成功（Gradle 15.7 秒）；APK 152551661 字节，SHA256 `56833186bd10932658627709ab0c15533c978ad907111bf2230d720546a8190a`。这是 x64 调试工程候选，不能安装到普通 ARM 手机，也不是正式分发包。

Windows `client_main.dart` 已在独立构建目录完成 Debug 构建；未启动普通可见客户端。其 exe SHA256 `797f0d56ac26c2e135edbe6ae87ef1066f618a28ec301c148da1ab1444063ef4`，只标识启动文件，不代表包含原生依赖的整个可运行目录哈希。

架构评审发现并修复：Android 退出失败后重试门闩、Windows 退出前等待存储排空、冻结后的键盘/语义操作，以及退休写盘失败不能阻止安全 Stop。实际使用的 `ClientShutdown`/`ClientCommandBarrier` 新增 9/9 受控与无窗口 Widget 测试通过，整包分析无问题；两条安全停止测试先实际失败后修复通过。架构复审有限批准进入原生验证。

关闭重试只重试尚未成功的步骤；已成功关闭的 Store 不再重复关闭。bookkeeping/host 的稳定失败 Future 保持 fail-closed，不能靠再按返回假装恢复，也不会在未确认清理时退出；需保留失败状态并诊断/重启。受控测试不等于真实 OS 退出已通过。

## Windows 真实原生串联

独立 Debug 入口 `client_background_regression.dart` 已在单独目录构建并实际运行。原生 runner 使用既有隐藏参数抑制首帧 Show/SetFocus；SMTC 回读逐步核对本进程窗口隐藏、无焦点、非前台。每次 Play 前只将自有 Player 音量设为零，不更改系统音量。素材为自造 12 秒静音 PCM，明确不是英语朗读或 TTS。

实际链路使用 `ClientApplicationOwner`、FileStore、缓存、Runtime、实际 Shell 回调、MediaKit 与自身 HWND 的 SMTC，没有受控 Engine/System 代替：

| 观察步骤 | 实际结果 |
| --- | --- |
| Open | paused，0ms；未自动 Play |
| 显式 Play | 观察 playing，位置推进至 700ms |
| Pause | paused，796ms；等待后位置稳定 |
| Seek | 实际到位 5000ms，同版 checkpoint 为 5000ms |
| Stop | 实际 idle/0ms，SMTC 退场；原 checkpoint 保持 5000ms |
| 显式重新 Play 后 Pause | 原生重新加载并推进，保存实际位置 750ms |
| 退出测试清理 | 确认 Stop，等待数据排空、原生释放与既有 6 秒回调保护，metadata 清空 |
| 不创建 Player 的 Store 重开 | 精确恢复 750ms，resumeIntent 为 paused |

本地回执 `passed=true`、`cleanupConfirmed=true`、`ownerCleanupRequired=false`，耗时 9536ms；合成临时目录成功清理。独立 QA 已逐项核对 16 个步骤、构建 target 与隐藏/静音准入，并确认本次进程已自行退出，有限验收通过。回执只含安全标量与固定状态码，原始文件不公开。

此结果不证明学习 Widget 在原生窗口里已交互验收，也不证明音质、TTS、真实锁屏、主机媒体键、Android/Apple 或专业评测。已渲染 Widget 的证据与本次原生回调链证据分别保留。

## 后续验收与资源条件

按 [交付门槛](M18-delivery-gates.md) 完成原生组装与有限运行，再接真实材料生成、配音、词典/复习和专业评测。当前云调用仍为零，F0 资源准备方案没有变成开通或付费授权。Windows/Android 工程验证不推定 Apple 或手机实机通过；真实听说与用户人工验收分别安排。

全程不激活用户桌面、不发送主机键鼠、不播放主机声音、不读取真人录音。原始日志、图像、音视频、安装包、SDK、私有目录和账号信息不进入公共 Git。
