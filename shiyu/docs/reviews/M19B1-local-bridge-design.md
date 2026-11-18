# M19-B1 本机候选桥接设计与权限合同

2026-11-18。承接 M19-B 工作包及 `docs/adr/0001-learning-candidate-confirmation.md`。只做外部文本候选→本人校对／确认→`partial`可读学习版。没有模型调用、音频、配音、发音评分、课程、自动公开或通用Agent执行框架。

## 模块与唯一文件归属

| 位置 | 职责 |
| --- | --- |
| `learning_core` | 同一FileLearningStore实例实现LearningStore与LearningCandidateStore；候选／确认映射／学习版同快照原子提交，外部来源声明与可信提交上下文分开 |
| `agent_bridge` | App持有的Root OS锁、私有descriptor、固定本机帧、受限Controller／Client；不另开Store权威 |
| `agent_bridge/bin/shiyu_agent_proxy.dart` | 独立纯Dart stdio MCP代理，可编译Windows exe放App `tools`目录；只读显式私有descriptor并调用App，不直接读写Store |
| AppOwner | 先RootLock再打开两个Store；注入默认关闭的授权／状态／高级接入说明；退出封门并drain后关Store，最后释放RootLock |
| Shell／runtime | 本人候选列表、校对、expectedRevision确认／拒绝、来源说明；高级连接配置只在“我的”入口，主学习流程不展示TOML |

UI入口 `agent_bridge_contracts.dart` 仅导出无副作用类型；App导入聚合实现。status不含token、端口、正文或私有路径。本人明确请求高级setup才获得无密钥的配置模板和descriptor定位，不能把它发进MCP响应／日志。

## Root单写者与关闭顺序

固定Root下 `.shiyu-owner.lock` 使用OS非阻塞独占字节区间 `[0,1)`。文件从不unlink；崩溃由OS释放句柄，不能把PID文件存在当锁。相同进程的路径／文件身份检查发生在任何create/open锁inode之前，避免POSIX第二句柄关闭时意外释放本进程已有锁。Windows区域unlock与lock一致。

此锁防合作应用实例／本代理并发写入，不承诺阻止管理员或任意OS文件写入。测试只使用新建临时Root和自己新启动的进程，不访问／停止旧录制程序。

退出同步禁止新授权／请求；关闭本机listener和socket，撤销cap并删除对应session的descriptor。已进入Core的写入不能靠网络timeout假装取消，须等待真实Future结束。之后按顺序关闭LearningStore、MaterialStore，最后释放RootLock。失败保留draining／错误，不提前宣称资源全部结束。

## 授权与来源

- 默认不监听、不恢复上次授权。本人选择一份已确认材料版本，最多15分钟授权；`source:read`默认关闭，勾选后只可读取该固定版的原文文本。外部助手可能把获准原文用于其自己的模型上下文，不等于App已获云模型／费用授权。
- `integration_id`为App固定逻辑连接器标识，跨cap／session稳定；不是Codex／WorkBuddy等品牌认证，也不信MCP clientInfo或请求体自称的owner/scopes。
- 固定绑定取自实际MaterialStore.readVersion及完整原文的严格Unicode／UTF8 SHA。所有read与submit均需精确material/version/hash；轮换descriptor不能把旧结果重标为新材料。
- 接收只能写本人私有学习候选。外部无候选列表／校对／确认／生成／发布权限。本人确认独立走Store Interface，B1产出`partial`，不能标可听。
- 回执`status=delivered`仅表示持久送达。重复投递的候选可能已被本人确认或拒绝，receive-only不披露当前处理状态，也不声称重放又创建了待审项。
- provider/model/version等仍是原样来源声明，未独立核实。传输cap有效不证明内容由某品牌模型产生、语言自然度或版权／音色许可。

## 私有传输：不是HTTP

本机server仅绑定字面`127.0.0.1:0`。采用带NUL magic的12字节固定帧头（magic8＋uint32大端长度），不是HTTP、WebSocket或MCP-over-HTTP，故Host／Origin字段不适用；HTTP／WebSocket前缀不匹配magic即拒绝。MCP只存在于外层stdio。

每连接仅两次请求：先无凭据hello(session＋随机challenge)，server返回HMAC-SHA256证明，绑定真实监听port／session／challenge；proxy验证后才在**同一TCP连接**发送cap及业务。断连不重新连接／跳转重发，避免过时端口或proof后端口复用收到正文／凭据。

| 预算／限制 | 实际合同 |
| --- | --- |
| proof帧 | 512字节以内，失败前不发送cap／业务正文 |
| operation／response帧 | 256KiB；实际完整编码超限即失败，不截断 |
| 原始业务JSON | 192KiB以内，base64置入operation envelope；最终帧预算优先，封套overhead也算 |
| 原文读取 | UTF8最多100KiB；超限提示拆分，不截原文 |
| JSON | 严格UTF8／合法surrogate，深度16、节点4096；反转义后的同对象重复key拒绝，不接受last-wins |
| 并发／时间 | 最多2个socket、1个真正Store operation；读帧2秒／socket总5秒。超时destroy socket但不释放未完成Store gate |
| 授权调用 | 每cap最多64次操作；新授权仍用同逻辑integration持久幂等，不绕Core候选容量 |
| Core输入 | 128双语句／合计100KiB，声明8KiB、pending32及保留JSON32MiB，仍由Core权威核验 |

凭据与proof key各256bit，仅私有文件／内存，不在URL、argv、stdout、普通日志、Git或业务摘要里。业务指纹对实际解码业务bytes计算，不把cap混入指纹。已可能提交但响应未知返回outcomeUnknown；只允许用原delivery ID按持久幂等核对，不自动换ID再发。

descriptor位于当前Root的保留私有子目录，Windows直接WinAPI核owner＋protected非NULL DACL，仅允许本人／SYSTEM；已有broad权限失败，未安全落权限前不写secret。拒绝UNC／reparse／Root外目录，WinAPI取canonical DOS路径去除只在特定执行上下文存在的R/SUBST别名。此保护不抵御管理员或同一OS账户内任意恶意程序。B1外部stdio首先仅Windows准入；Android／Apple端不假称已接入。

## MCP业务工具与严格输入

1. `shiyu_get_source_reference`：返回授权目标的三个不透明ID／摘要字段，无正文／标题。
2. `shiyu_read_fixed_source`：必须提供上述三字段，并另具原文scope；只返回该固定原文。
3. `shiyu_submit_learning_candidate`：schema_version1、material_id/material_version_id/source_text_sha256、delivery_id、双语sentences、来源declaration。任何media字段出现（包括null）明确unsupported，不悄悄忽略。

stdio采用标准UTF8换行JSON-RPC，initialize／initialized／tools与两明确支持版本2025-11-25、2025-06-18；无sampling／prompts／roots。实际stdin限256KiB，输出完整有界编码后才写，stdout只有协议。MCP会话唯一ID集合有4096上限，达到后结束会话，不无限保留历史。

代理启动只接受环境变量`SHIYU_BRIDGE_DESCRIPTOR`的文件定位，不接收argv中的凭据、路径或URL；模型tool参数不能选择执行程序／连接地址。独立exe不需要普通用户安装Python／SDK，不把R映射下开发脚本误当普通Codex环境可启动的正式配置。

## 已核官方资料与真实接入门槛

- [Codex MCP官方指南](https://developers.openai.com/codex/mcp) 当前转到 [ChatGPT Learn MCP页](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)：支持stdio command/args/env，配置在config.toml；当前桌面步骤说明保存后Restart。没有证据证明本聊天可热加载新工具，不承诺它。
- [MCP 2025-11-25 transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)、[basic请求规则](https://modelcontextprotocol.io/specification/2025-11-25/basic)：stdio帧／初始化／工具与会话ID规则依此实现。
- [Microsoft SetNamedSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setnamedsecurityinfow)、[GetNamedSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getnamedsecurityinfow)：只处理本App私有目录／descriptor；GetCurrentProcess伪handle不Close，Token handle Close，LocalAlloc结果LocalFree。

精确依赖为现有`crypto3.0.8`、`ffi2.2.0`与本地Core，未升级；ffi许可证实际为BSD风格而非MIT。真实Codex等产品的配置／reload与本人验收留到可审exe／配置／授权目标齐备后的最后一步，不复用其账户、现有CLI或TTS，不重启／操作主界面。

受控子进程／实际本机帧／Store通过仅证明该传输与数据链，不能改名“官方Codex已连通”；必须由真实外部工具实际调用并在App回读后才另记连接证据。
