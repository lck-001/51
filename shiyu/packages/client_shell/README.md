# client_shell

拾语 v0.13 的首个真实本机业务 Widget 包；不是新原型，也不是完整上线 App。无需运行桌面窗口、播放器或云服务即可测试与导出渲染图。

## 稳定小接口

```dart
ShiyuClientShell(
  materials: materialStore, // 外部打开并绑定可信 owner
  learning: learningStore, // 必须同 owner
  playback: playbackView,  // ValueListenable<ClientPlaybackView>，可不提供
  onOpenLearning: openVersion, // Future<void>(LearningVersion)，只打开不播放
  onPlaybackCommand: dispatchExpectedVersion, // Future<CommandResult>(expected, command)
  onLookupWord: lookupWord, // Future<WordLookupResult?>(WordLookupRequest)
  onPractice: beginPractice, // Future<void>(PracticeRequest)
)
```

Root 用 `learning_playback` 的公开协调器桥接：

- `onOpenLearning` 调 `coordinator.open(version.binding.learningVersionId)`；将 pending/rejected/superseded 按实际结果处理，不能转为已加载成功。
- `onPlaybackCommand` **先核对** `coordinator.current.binding.sameAs(expected.binding)`，再 `dispatch(command)`。UI不会直接操作Player或解析文件路径。
- `ClientPlaybackView(learningVersionId:, snapshot:)` 必须原子配对同一学习版与实际Playback快照。UI同时核对owner、公开学习版itemId与mediaVersionId；错误绑定不给播放／定位按钮。
- 外部App拥有Store、协调器和Native生命周期；Widget dispose只销毁自己的文本控制器，不关闭Store/播放器。

异步打开、查词、命令结果均核所选学习版和本地epoch；旧A结果不能写进B。换账号Store时清掉旧内容、选择与在途结果。Callback执行内部的取消／授权／资源责任仍归其所属模块，UI丢弃结果不等于底层任务已取消。

## 本包实际能力

- 一级导航：学习／材料／中间添加＋／分享／我的；学习阅读详情按m11保留返回入口，不让底部导航挤占词卡。
- 添加只做粘贴文字。保存使用真实 `MaterialStore.createDraft/updateDraft` 并回读；确认调用 `confirmVersion` 创建固定版本。未保存修改不可直接确认。
- 材料列表与“我的”统计来自同owner真实Store；Widget移除并重开Store后仍可读取。没有云同步、第三方上传或自动翻译。
- 学习只展示LearningStore已有版本；pending/partial/ready分别标记，manual／synthetic分别说明。材料确认不会自动编造英文、配音或学习任务。
- 阅读顺序固定：独立滚动的完整英文／已提供中文 → 实际进度与播放控制 → 练习按钮 → 最底部两行可展开词卡。当前采用实际m11 CSS的18px英文正文与系统字体，不重新设计布局。
- 缺少词典时保留点词提示，点击后明确未接入，不提供杜撰IPA／释义／收藏成功。录音、专业评测、示范发音、分享等没有Callback／服务即明确空态或禁用，不产生假分。

## 后台验证与图像证据

依赖固定 `material_ui: 1.11.0`，`flutter_test` 使用当前Flutter SDK版本；新包lock保留。首次本机缓存缺测试依赖时只补齐SDK约束依赖，没有升级Flutter或其他包的lock。

```powershell
flutter pub get --offline
flutter analyze --no-pub
flutter test --no-pub --reporter expanded --timeout 45s
```

Widget tests使用临时真实FileMaterialStore/FileLearningStore与内存生成的静默PCM／手工自造双语结构fixture，不启动NativeEngine，不播放、不录音、不发云请求、不创建桌面窗口或发送真实键鼠。测试代理只把实际FileStore调用委托至real-IO Zone，避免Flutter fake clock与runAsync互等；没有用内存字典伪造存储或削弱持久化断言。

测试同时用RepaintBoundary在无窗口tester中导出 `results/materials-mobile.png`、`results/learning-mobile.png`、`results/learning-word-expanded-mobile.png`（390×844，目录被ignore）。可加载本机Segoe/YaHei字体用于中文渲染，不复制字体入库。

PNG只证明该Widget构图，临时合成学习版的ready只证明版本／制品结构，不证明英语生成、配音对齐、真实Native播放、专业纠音或四端人验。桌面完整d01/d02工作台与其他格式入口仍按已批准需求后续接入。

当前阶段：客户端首闭环实现与后台Widget验证；下一步Root审图、独立QA及App窄桥接；用户当前无需操作电脑。
