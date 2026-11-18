# M19-A：持久生成任务的本地验证实现

这是现有后端的独立 generation 模块，不是通用工作流平台。它不注册账号、调用真实供应商、生成真实英语/语音、启动网络监听、接客户端学习版或后台自动执行任务。HTTP facade 与 Dart manifest 均未改动。

## 业务 Interface 与来源

`GenerationService(materials, jobs)` 只向业务调用方提供：

- `create(caller, material_version_id, request_id, options=GenerationOptions())`
- `get(caller, job_id)`
- `cancel(caller, job_id, expected_revision)`

沿已有 `TrustedCaller` 服务器可信上下文；它本身仍不是认证器。创建需要独立的 `generation:create` 和 `materials:read`；查询/取消分别需要 `generation:read` / `generation:cancel`。接收材料的权限不会隐含获得这些权限。来源必须由现有 MaterialRepository 返回已确认的本人固定版本，草稿与他人版本按 not-found 拒绝。源文字、标题、原材料/版本与内容 SHA 在私有数据库冻结；客户端不能提交 owner、批准标志或供应商地址。

同 owner/request 持久幂等；更换版本或配置是冲突，不创建第二个任务。JobView 仅返回固定绑定、revision、阶段/状态、稳定原因、结果引用和预算状态，无源正文、音频、文件路径或原始异常。所有新任务默认 `blocked/resources_unavailable`，创建不会发起执行。

## 单独的内部 fixture worker

`FixtureGenerationWorker(jobs, FixtureAdapter(...))` 是受控内部 seam，不能暴露给普通业务调用方。`admit` 校验明确的能力与内部 `ValidationGrant` 并原子预留；`claim` 持久领取 attempt/fence/operation-key；`run` 再原子提交一次性 dispatched 位，防止同一 claim 重复或并发执行。`recover_expired` 只把不确定任务冻结为 uncertain，不重发。

本包没有生产 ProviderAdapter、动态加载、供应商注册表、凭据或网络客户端，唯一可注入的是明确 fixture 的受控 Python callable。代码与输出强制标 fixture，结果 `client_learning_ready=False`，不因 completed 进入用户学习列表。注入代码属于可信进程代码，**不是对恶意 Python 代码的网络安全沙箱**。

只支持已列出的 `en-US / us-conversation-v1` 结构计划；能力缺失、权利/计量未知和配置不符保持 blocked。准入能力指纹持久化，并在 claim 与 dispatch 重新核对，不能用另一套未知配置执行已排队任务。单次 bundle 实际执行后再校验/打包，不显示虚构的多阶段进度。

## 预算、取消与未知

每个内部验证授权按 owner/grant/unit 固定整数账本，单位、上限、单任务预留、配置与最大调用数不可用同 grant 悄悄更换。并发预留依赖真实 SQLite `BEGIN IMMEDIATE`。即使已知用量为 0，也有独立、持久的 reserved/submitted call 上限；`max_calls` 默认 16 只是本地 fixture 门槛，不是用户云授权或免费量。

- blocked/queued 取消不执行，释放未用预留；已领取但尚未 dispatch 的取消可确定不出站。
- 正在执行先 cancel_requested。晚到明确响应仍结算已用额度，但取消获胜不发布结果。
- 普通异常、超时、过期 token、重启后的未知窗口均保持 uncertain/unknown held。租约过期不等于未执行，不能重领重发。
- 缺用量、负数、错单位或超过原预留的用量不填 0、不结算成成功，保留未知占用。
- 只有显式 `DefinitelyNotSubmitted` 正证可以释放单位预留；本地已启动 dispatch 仍保守占一次调用数。坏产物也不退还已知实际用量。
- 没有对外 retry/reconcile 快捷入口。未知结果需另行引入有证据的核对流程，不能删账本或换请求键绕过上限。

## 私有结果与交接清单

固定输入上限 100,000 UTF-8 字节；每个 fixture bundle 最多 128 句、100,000 字节双语文本、2 MiB WAV。验证实际 PCM16LE/16kHz/mono 容器、真实可读帧数/时长、非空双语字段、句时锚顺序及边界。均匀时锚只是本测试的 fixture 数据，不冒称真实声学对齐。

先保存私有 SQLite BLOB/句数组，再经有效 attempt/fence/租约与取消状态 CAS 提交不可变清单。崩溃/过期可留下不可见 staged 候选，不把文件存在当作成功，不清空原数据恢复健康。已提交结果不可由重复 run 再发布/结算。

`inspect_result(owner, ref)` 只给受控内部读取安全交接清单：owner/material/version/job/attempt、输入/音频 SHA、字节/时长/句数、plan/schema/policy/config/voice 引用、fixture 来源和未导入状态。双语句数组和音频留私有存储。字段由执行链的冻结输入、token 和实际 fixture 配置生成，不采信结果自报归属。下一包仍须评审 Dart 来源 Schema 与窄导入映射，不能直接写 manifest 或把 fixture 标成人工/真实模型内容。

## 存储与实际验证范围

`SQLiteGenerationValidationRepository` 使用单独的真实本地验证文件，不改原材料数据库的迁移版本，不是 PostgreSQL 生产适配。其他用途或损坏的数据库拒绝打开，不重置数据。原子预算/领取/清单的本机 SQLite 证据不推定真实认证、多节点、PG、费用结算、断电耐久或灾备通过。

实际命令（后端目录）：

```console
python tests/test_generation_local.py -v
python tests/test_generation_independent.py -v
python tests/test_intake_sqlite.py
```

本方 supplemental 测试 5/5、独立 QA 18/18 与原 intake 回归 27/27 已实际通过。独立测试包含同 claim 并发/重复执行、原子预算、真实子进程领取后崩溃恢复、晚到取消/过期响应、跨 worker 配置、未知策略、零用量硬调用上限，以及 SQL 故障注入后的 staged 候选不可见/不重发；源码架构有限验收通过。Supplemental 首次两项清理错误是测试直接使用 SQLite context 后未关闭句柄，已改显式 closing；没有放宽存储/预算断言。所有测试用临时文件、合成身份、原创结构文本和静音 PCM，真实供应商调用为 0。

根另实际执行后端完整测试发现：`python -m unittest discover -s git-checkouts/51/shiyu/services/backend/tests -v`，60/60 通过，包含原材料/受限送入、实际 localhost HTTP 和新增生成任务测试。该本地回归仍不等于真实外部 Agent 或公网认证已接通。

当前阶段：M19-A 本地实现与独立验收通过，纳入功能分支管理。用户选择暂不开通账号，真实供应商仍零调用；团队继续 M20 文件导入等无需账号的工作，来源 Schema/窄导入按 M19-B 单独评审。用户当前无需操作；fixture completed 不能作为个人体验候选交付。
