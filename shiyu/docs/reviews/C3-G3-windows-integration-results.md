# C3-G3：Windows组合链与关闭验证

2026-11-24。Windows普通入口与专用验证入口分别构建。专用v4已实际完成两项启动拒绝、空资料退出和完整合成链路，独立QA只读核验收据、冻结源码和存储实物后有限准出。本记录不代表普通界面已人工验收、正式发布或四端交付。

## 生产修复

程序化退出曾完成停止和存储关闭，却没有真正退出：WindowsHost已移除消息处理器，原生窗口仍等待closeReady票据；SystemNavigator返回不能证明进程结束。

- 保持ClientShutdown的Stop、真实Store/A drain、host关闭顺序。Windows退出闭包复核实际stopped、writersDrained、authorityReleased及锁已释放，再请求原生程序退出票据。Android仍走原路径。
- Host关闭保留精确Future，事件流等实际结束后才标完成。原生beginProgrammaticClose只生成或返回当前真实pending票据，再复用closeReady提交窗口关闭；不复活旧业务处理器，不解除generic Retire的关闭屏障。
- 调用者超时或结果未知不另发请求；只有原生明确close_post_failed才允许下一次显式请求重试。startup失败分支只有全部清理及存储权威关闭成功后才显式detach，否则保守失败。

公共运行源码基线为本地检查点`9cc4361b6afb1c020dc92f8b5571a96eb5a739f3`；专用探针为另外冻结的私有合成验证代码。其环境守门、数据根和收据不属于普通应用入口。产品源码与测试纳入Git；包含个人环境路径的诊断工具、运行资料和原始日志保留私有，不绕过公开源审计。

## 实际证据

| 层 | 结果与范围 |
| --- | --- |
| WindowsHost/关闭/存储独立回归 | 单次49/49，exit0；17新host、11原shutdown、21原Storage，8项SHA前后相同。MethodChannel为受控适配；不是物理退出证据 |
| 独立源码审阅 | 生产四文件固定SHA通过有限审阅，实际AppOwner及原生票据运行由下列专用目标覆盖 |
| 专用v4静态完整性 | 25/25文件大小和SHA一致，总213263096字节；9份Dart和10条freeze记录一致；kernel为专用目标，runner与公共基线一致 |
| 启动拒绝 | 缺静音、错误代理SHA两例均保留background标志，实际exit64，无profile或检查点创建 |
| 空资料退出 | 真实AppOwner、未选择媒体、无授权/代理/播放；真实Store/A与Host关闭后精确自有进程自然exit0，无watchdog |
| 完整链路 | 精确自有进程自然exit0，无watchdog；退出前检查点与PID、源码基线、代理SHA及case绑定 |
| 独立运行证据验收 | 四组实际收据、存储实物、ACL及冻结源码核对通过；QA未重复启动native，与Root实际执行分开记录 |

专用App SHA：`7a43cec6858db4afe03c5fd86bdd882282f16f7bb008c048f5c8af19247a5ecd`。代理SHA：`8369e40c2bf2778cee1cc5389799d39c47cf895081bd023583d928481ce25f7a`。专用source freeze SHA：`35703e77e19d2465b2174b8859b2b0f088ba16196dd23f154ff16c687d87bfa9`。这些不是普通界面包的SHA。

完整链路包括：真实bundle代理发现八工具与必要schema；两个许可均false时，原producer、原SDK与独立认证consumer的begin均拒绝，实际文件和journal不变；元数据提交重放及媒体两遍读取、分块、seal/submit/abort；同一组真实材料和学习Store中的候选及合成确认。

SDK读取两遍，两个source均实际naturalDone、close和cancel结束。零PCM通过真实缓存与MediaKit，观察播放位置从约700ms推进、暂停/定位，保存5000ms进度；关闭首owner后沿同A入口重开、重新取得唯一锁，两个版本和确认状态持久化，恢复后再观察约5690ms播放位置。两次退休均观察到已受理write尚未完成，等待其真正结束后才关闭L/M并释放A。代理EOF没有被当成存储drain。

各运行阶段观察自有窗口不可见、不持焦点、不处前台；每次Play前仅将自有Player音量置零，未改系统音量。Root执行以上实际case，独立QA仅复核收据、冻结源码和留存证据时，必须与其自行启动运行区分。

独立QA核到完整链路15次、空资料3次隐藏状态观测，七处实际ACL均为owner+SYSTEM双ACE、protected/OICI；空资料Store保持空，完整链路留存两个确认学习版本及一个进度记录。退出前检查点仍明确naturalProcessExitVerified=false，进程真实退出由持有确切Process的launcher另证，未用检查点替代物理退出。

## 原失败及修正

- 首个专用v3把384044字节放入一个source事件，超过SDK65536限制，实际sourceInvalid且尚未发业务工具；自然EOF断言又遮蔽原错误。实际SDK反馈环保留红例，v4分为六片，先记录真实outcome，仅成功时要求两次自然EOF，失败仍等待自有source清理Future。
- 同次失败完成真实清理后，原生窗口仍因关闭票据断链留存。只读VM状态排除第二Stop挂起，随后窄修生产Windows退出链。旧测试在确认所有资源排空后才精确HANDLE强制exit42回收；原run始终failed，强制回收不算自然退出或功能通过。
- 深测试根使缓存路径达到316字符。原Win32只读路径访问错误3，扩展路径访问成功；原fixture只等待rename进入，掩盖了先发生的cacheCorrupt。未升超时、删断言或改变G1/ACL；浅层C TEMP下原49项全部通过。

专用v4仅使用同workspace的固定短测试根，同一AppOwner/G1工厂和隐私守门不变；当前root77、最坏cache-next232，启动前限制104/259。该选择不解决既有长路径兼容限制。普通入口路径未改，未迁移或读取旧用户资料；普通用户实际KnownFolder、重定向或更长profile须另验。

## 尚未覆盖

普通client_main与专用probe是不同入口，不能把专用包交给用户当正常产品。下一步单独核验并准备普通Windows包、人工步骤和校验值。startup post-host失败没有可靠的无hook原生故障触发，本轮仅源码与受控headless证据。真实系统选择器、听感、系统锁屏/蓝牙/媒体键、所有设备与OS错误矩阵未由本次认证。

合成确认不是本人审阅，零PCM不是英语朗读，更不是专业发音评分。真实模型/TTS/专业Speech、词典词句本/复习/看板、共享反馈/账号等完整能力不在此片补齐；没有云调用。Android维持单列工程候选，iPhone和Mac未由Windows证据外推。未合主分支、未灰度或正式上线。
