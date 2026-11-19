# B2-A 首包：制品幂等登记与恢复保护

本包仅交付 MaterialStore 能力，不开放音频上传、媒体学习候选或播放。接口与恢复规则经独立架构评审后实施，再由独立 QA 实跑验收。设计见 [Material ADR](../adr/0002-material-registration-recovery.md)。

## 行为与边界

- 独立 IdempotentArtifactStore 提供 registerArtifactOnce 与 operation 查询，不要求既有 MaterialStore 适配器增加能力。上层负责可信业务键派生；Store 只校验格式与当前 owner 分区，不把摘要当身份认证。
- 相同操作键和实际完整 bytes 返回原引用；换内容冲突。输入先限长并复制，实际摘要、长度和已有制品逐 byte 比对在权威队列内完成。操作映射与制品登记共用一个 schema2 快照。
- 正常主快照完整时，提交成功但回执丢失可按原键查询／重试。blob 已落盘而主快照未提交可留下孤儿，不猜作成功，也不宣称零残留。
- schema1 无损升级依次写 schema2 backup、primary、marker。旧 B1 正常初始库只有 primary 和 marker、尚无 backup，也有明确迁移路径；坏或不可读 backup 不当作不存在。
- 主损坏回退旧 backup 可能已丢成功映射，先持久 hold 再恢复历史数据；hold 跨重启封住快照写及 operation 查询，不自动解除。无法持久 hold 时保留故障现场，不先覆盖后报错。历史读取仍验证完整性。
- 新注册初值为单份 2MiB、128 operations、artifact 目录实际保留 64MiB。未知文件、孤儿和残留计额；历史大库不删、仍可读。legacy import 保持原行为，因此这是新注册准入预算，不是整个 Store 或设备的硬配额。
- 旧 reader 拒绝 schema2 不等于能阻止旧驻留 writer；升级前须结束旧实例。进程故障证据不等于断电耐久或不可恢复损坏零丢失。

## 实际验证

| 验证方／范围 | 结果 |
| --- | --- |
| 作者 Material 分析与原有回归 | 分析退出0；30/30退出0 |
| 作者新登记／恢复回归 | 18/18，真实退出0 |
| 独立 QA 重新执行原有与新增回归 | 30/30、18/18，均退出0；分析退出0 |
| 独立 QA 补充验证 | 7/7，退出0 |
| 另一同学验证实际消费者 | 导入、来源、组合与关闭四文件24/24退出0；整 probe 分析无问题、退出0 |

独立补测以冻结旧 B1 源码实际生成初始无 backup、完整库及 64MiB+1 历史库，核对无损迁移与旧 reader 拒绝新 schema；另验12次并发与输入 buffer 变异仅登记一份制品、hold 连续三次重开封门、未知 regular／.next 文件计额且不删。独立 VM 在实际提交后，由父进程读取真实 operation／blob，再终止自己的子进程；重开按原键取得同 ref，sequence 不增。

作者真实 VM 故障回归还覆盖迁移边界、blob 落盘未建索引、提交回执缺失及容量。子进程核对实际 dartvm PID，不把 launcher 退出当 VM 崩溃，不操作用户程序。

## 保留的失败

实现初期 schema1 backup 恢复曾把未补 operation 字段的旧 payload 写入 schema2 验证路径，已改为使用补齐结构且仍处于 hold 的历史数据，并补真实回归；未放宽 schema2 校验。

测试发现重复 confirmVersion 的已有结果早返绕过 hold，已将门禁移到早返前。作者一轮测试虽断言完成，但 StreamIterator 未关闭导致进程不退出，该轮中止退出1不算通过；关闭订阅后全部重跑，真实退出0。早期编译和这些失败记录保留于私有执行记录。

## 未覆盖

独立补测未实际构造 ACL 拒读、Windows 链接或 SHA 碰撞注入；相应封门与完整 bytes 比较经源码审查，不写成已实测。没有用户数据、云账号、TTS、音频资源或桌面输入操作。

本包不包含 Learning 媒体 schema、分块上传、journal、桥接新权限、WAV 策略、App 界面、自动 GC、真实朗读质量、四端设备、人验或发布。下一项仍须按已评审边界分别实施与验收。
