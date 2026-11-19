# B2-B：媒体学习候选与版本一致性

本包仅在 LearningCore 增加结构能力；不开放上传、stdio 新工具、界面或播放。接口、来源、修订和迁移方案先经独立架构评审，三个歧义收口后实施。设计见 [Learning 媒体 ADR](../adr/0003-learning-media-candidate-schema.md)。

## 最小行为

- 新增独立 LearningMediaCandidateStore 能力，复用原候选读取、校对、确认和拒绝接口。B1 仍为文字候选，原业务指纹和 delivery 命名空间不变；新媒体 delivery 不能绕过旧键冲突。
- 从实际固定原稿、精确有序英文和已登记的媒体 bytes 分别核验指纹。媒体只接受本包严格 PCM WAV 与有界时锚策略；旧 manual／synthetic 媒体仍用原兼容策略。
- originalMedia、媒体声明和时锚来源为不可变审计。纯中文译文修改可保留匹配；英文字符、增删或顺序变化记录首次失效，改回也不自动挂回音频。保留原媒体引用和失效原因，不静默抹掉来源。
- matched 确认须重验源、真实媒体、绑定与时锚；缺失或损坏不确认。invalidated 可确认成无可播放媒体的文字 partial，即使旧 blob 缺失仍保留审计；实际源、修订、结构及双 Store 恢复门禁仍须有效。
- 媒体 provenance 的 external 部分完整复用文本确认上下文；音频自述另存 originalMedia／externalDetails，不用音频声明替换文本声明。有效格式、用户确认或可信投递均不等于朗读、版权或模型认证。
- 固定候选修订、确认映射与新学习版共用一个 Learning 快照提交；新媒体版不覆盖旧 partial、句锚或进度。不是跨 Material／Learning 事务。

## 升级与恢复

schema3 先保存原 schema1／2 归档、写 backup3，再 primary3 和 marker3。旧 B1 记录缺省 inputVersion 严格为1，迁移不补字段，避免原32MiB临界库因字段膨胀越额；所有新增或修订仍按实际完整记录计额，不扩额或删历史。

需要退旧备份时先持久恢复 hold，不能持久则保留现场失败。hold 跨重开封住快照写、terminal／replay 早返、候选查询和新播放准入；历史版本及 paused checkpoint 按实际完整性读取。v2 每个持久动作准入前核对两个 Store，已进入 commit 的操作等待真实完成，不假装跨文件回滚。

旧 writer 已在内存时不受 marker 阻挡，升级前须结束旧实例。进程故障测试不证明断电耐久或不可恢复损坏零丢失。

## 已实际执行与独立验收状态

| 范围 | 实际结果 |
| --- | --- |
| 作者 Learning 原回归 | 25/25，退出0 |
| 作者候选本地回归 | 4/4，退出0 |
| 作者候选独立套件 | 10/10，退出0；7项业务断言不变，3项按批准更新 schema 专属断言 |
| 作者新媒体／升级回归 | 20/20，退出0；分析无问题 |
| 独立旧基线 | 从 ff03ae2 提取实际原源码和原候选测试，10/10退出0，未改旧断言 |
| 独立存储 QA 复跑 | 上述25、4、10、20项合计59项全部退出0；分析退出0 |
| 独立补充与中断升级 | 7/7及另一次真实中断升级1/1，均退出0 |
| 消费者独立回归 | Probe24、Shell24、Runtime12、播放协调器22，合计82项退出0；整 Probe 分析无问题 |

新结构包已通过独立存储 QA 有限验收，无阻止本范围交付的 P1。作者20例中的确切32MiB容量 fixture 为合成重封套，用于边界验证；不把它称为实际旧 writer 生成的库。

独立 QA 另从 a6497bd／ff03ae2 的实际旧源码运行公开接口新建 schema1／2 库，含 pending／confirmed／rejected 三种旧候选、8kHz manual 媒体和 paused checkpoint。另用旧 schema2 公开接口及合法合成大标题实际写出恰33554432-byte候选记录；schema3迁移后的完整payload与候选记录无字节增长，超额新增拒绝且不写入。该证据与作者的合成重封套fixture分开记录。

独立补测还验证文本／音频声明分离、同bytes不同ref重放不替换原引用、matched缺blob拒绝确认、sticky失效后改回且缺blob仍可partial确认、Material已hold时terminal早返拒绝，以及Learning hold三次重开封门。真实old1→old2未完成迁移→schema3的额外边界保持历史值；不通过手改envelope版本号代替实际旧writer证据。

## 保留的失败与测试适配

原候选测试三项写死 schema2／backup2 或原边界报错分支，在已批准的 schema3／持久 hold 语义下失配。独立 QA 裁定仅这三项适配：当前主备与 marker3、真实 backup3 与原 schema1 归档的中断升级、旧 writer 覆主后的精确持久 hold 与主备 bytes 保留；原 ID、来源、paused checkpoint、归档和封门保障保留或加强，其余7项业务断言不变。旧原测试在旧基线另行实跑，不 skip 或接受任意异常。

作者早期虚拟 IO checkpoint 未完整代理 open，且曾截到 Material marker，导致故障测试失败；后改为只拦 Learning 分区并真实代理 IO，再跑实际 VM 检查点。早期编译和这些失败保留在私有执行记录，不修改 Material 或用伪成功代替真实提交。

## 未覆盖

只用自造 bytes／静音及结构时锚，不证明英语朗读、语义对齐或声音质量；机器 ready 仅表示资源和结构可用。消费者回归未启动原生 Player、窗口或声音，不增加原生四端证据。

上传 journal、chunk、bridge 新权限、UI 提示、真实音频、专业发音评测、自动 GC、四端实机、人验和发布均不在本包。不调用新账号、云模型或 TTS；用户暂不开通 Azure 的选择保持有效。
