# C1：本机受限媒体接收结构模块验收

2026-11-23。本包只新增 agent_bridge 内的 media_ingest 模块、公开导出与可执行 Dart 作者测试，不接 socket／stdio、Controller、App 界面或 Player，不改 Core、依赖和 Schema。

## 已实现的合同

- begin 仅接收有界 manifest，不要求完整音频或学习正文。完整 PCM 和时锚在收齐后的 seal 及注册前 submit 校验，不能要求开始上传前检查尚未收到的 bytes。
- 分块非末块固定64KiB、末块等于剩余长度；顺序、实际内容摘要及重复块重放均校验。先持久接收事实再 ACK，journal 失败后封门，不凭内存返回 replay 成功。
- seal 返回256-bit随机 receipt；submit 需要该 receipt 与完整学习输入，并实算英文和完整语义指纹。文本与音频声明独立保留，不混用或补造 provider／model。
- 业务键、注册操作键保持稳定。注册制品及候选分别由 Material／Learning 权威查询，journal 不复制 ArtifactRef、candidateId 或注册／投递结果。两者不是跨 Store 事务。
- receiving 重开先按可信内部生命周期终止，只有权威明确未注册、未投递时才清受控暂存；sealed 重建后要求新同绑定授权，按原 receipt／操作键重试。权威错误或不确定进入持久 hold，不按“没有记录”处理。
- abort 先认证再同步封门；retire／close 也同步阻止后续持久步骤，等待已进入 Store 的真实 Future。Material 已提交时可阻止下一次 Learning 调用；Learning 已提交则保留真实候选，不假装取消回滚。
- primary／backup 都做完整结构与单向状态检查，receipt、块前缀和清理状态不得倒退；不回退旧 backup 猜最新事实。hold／marker 使用 no-follow 检查，拒绝 dangling link。unknown、terminal、残片及清理失败均保守计额。
- module 不拥有或关闭调用方 Store。rootLock、同一对象能力和 owner 检查保留；Learning 与 Material 的内部实例联系由可信装配及其测试证明，不声称能运行时检测所有同 owner 的错误拼接。

## 冻结与实际证据

验收源码 SHA256：`48b435b269c9476424a525e8d6a0e49795ab4ab5668ea8e1a8e93cd12c5b8209`。

| 验证 | 实际结果 |
| --- | --- |
| 作者公开行为脚本 | 17组通过；分析无问题 |
| 独立真实行为 QA | 17项通过，退出0 |
| 独立故障 QA | 4项通过，退出0，无跳过 |
| 冻结一致性 | 独立测试前后源码 SHA 均与上述相同 |
| 独立架构 | 固定 SHA 源码复核，无剩余阻断 P1；该角色未自行重跑 Dart |
| 既有文字桥接兼容 | bridge_independent 6/6，退出0；整包分析无问题 |
| App 导入集成分析 | 完整 Probe 分析无问题，退出0；未增加原生运行证据 |

实际 QA 使用 RootLock、真实 FileMaterialStore／FileLearningStore 和私有文件，合成 WAV 为160044B，包含两个完整64KiB块及末块。验证基本提交、sealed新授权重试、receiving重开终止、错误取消不影响原业务、非法receipt／正文／声明／Unicode在注册前拒绝，以及close／abort的同步停止。

在真实 Material 或 Learning 已完成提交后，用薄委托仅暂停向 module 返回结果，验证三种停止操作会真实 drain：Material 边界后的 Learning 数量为0；Learning 边界后的候选仍为1。委托不伪造 ref、receipt 或磁盘结果。

注册 ACK-gap 用例是实际 Material 原操作键提交后，关闭并重开组件核对原ref与唯一候选；这证明持久化／重开核对，不称模块进程强杀或断电耐久。

故障覆盖 journal 写失败后不得假 ACK、取消与新 begin 不得复活 receiving、真实 dangling hold link 不得写穿私有根，以及 checksum 正确但非法 backup 状态必须 hold。链接目标仅在任务自有测试目录内，未跳过，未改系统开发者设置或用户目录权限。

## 保留的失败与修正

- 原测试配置含失效 R 盘 URI／错误编码，本轮重建 canonical 配置，验证六个依赖目录；Probe生成配置另核108个根。未改锁文件或依赖版本。初期分析环境错误不计源码缺陷。
- 旧测试把32000B作为非末块，违反64KiB合同，没有通过放宽分块规则取得绿。
- 首块真实 journal 曾因整数 Map 键无法 JSON 编码而失败；后改为规范化字符串键。新接口编译、目录尾斜杠误判和私有 ACL 的受限工具身份问题也保留原记录；ACL测试使用同拥有者权限，仅处理各自合成临时目录，不放宽保护或改祖先 ACL。
- 把 begin 改为必须有 initialBytes 的中间版本与分块合同冲突，已恢复 manifest-only。C1没有实际 wire，使用 controlledTest 来源，不把自己重编码的结构化输入冒作真实传输 bytes。
- checksum 正确但 backup.phase 非法在固定中间源码上实跑失败，修为完整恢复校验后在最终冻结版本通过。其他三个静态审查疑点在该中间快照中已被修复，对照测试为绿，不伪造旧红证据。

## 限制与下一阶段

本包未覆盖真实模块 VM 强杀、断电、所有 ACL 拒绝路径或跨平台权限；hold 写失败、全部物理暂存配额边界和锁已释放等可继续保留为后续破坏测试。没有真实朗读、播放、发音评分、四端设备、人验或发布结论。

C2仍需单独评审并接入受限 wire／stdio，C3再接 App 授权及实际音频。分块 bytes 由代码搬运，不让模型逐块生成 Base64，也不把它写入对话或一般日志。当前不调用云模型、TTS或新账号。
