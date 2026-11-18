# M20-A TXT／DOCX 本机导入架构与准入

2026-11-18。承接 M20 产品工作包；同行条件准入后实施，不新增 localhost 服务、账号、云任务或材料库。本文件记录设计，不把候选限额、源码检查或构建当设备验收。

## 已核查的实现事实

- 已锁 `file_selector:1.1.0` 的安卓 Adapter `file_selector_android:0.5.2+11` 在 `FileSelectorApiImpl` 根据供应商 SIZE 创建 `new byte[size]`，再 `readFully`；Dart 获得的是 `XFile.fromData`。故安卓文档路径不调用该插件；不能在 Dart 先检查 length 就宣称分配前有界。
- `archive:4.6.0` 为当前应用已锁 MIT 依赖。`ZipDecoder` 会覆盖重复 part，并在符号链接分支提前 `readBytes`；本切片不用该入口。公开的 `ZipDirectory.headers` 提供懒中央目录，`ZipFile.decompress(OutputStream)` 允许自有有界输出。库内部 `_outputLimit` 依据头部声明，本 Module 另核每次实际输出与合计，不单信声明。
- 拟精确新增 `xml:7.1.0`（MIT），其传递 `petitparser:7.1.0`（MIT）；现有 args2.7.0/meta1.19.0/collection1.19.1 已满足。archive4.6.0、crypto3.0.8、path1.9.1 不升级。实际离线求解与 lock diff 另验。

## 文件归属与 Interface

| 位置 | 责任 |
| --- | --- |
| `packages/material_import/lib/material_import.dart` | 冻结类型、稳定错误、限额、无路径预览及会话 Interface，由客户端架构师维护 |
| `packages/material_import/lib/src/` | 独立纯 Dart 提取 Module；解析工程师实现，同行独立验收 |
| `validation/playback-01/lib/client_material_import.dart` | App 拥有的会话、私有临时副本、worker、来源制品及保存核验 |
| `validation/playback-01/android/.../BoundedDocumentImport.kt` | 独立 SAF 有界读取 Adapter；播放宿主不承担文档权限 |
| `client_shell`／`client_runtime` | Root 接单个 `StartMaterialImport`，复用编辑／草稿／确认／列表流程 |

`MaterialImportSession` 只有 `sessionId/ownerId`、`preview`、`prepareArtifacts()`、`cancel()`、`finish(savedMaterialId)`。UI 不拿 OS 路径、content URI、解压器或 worker。`preview=null` 表示取消；错误只用稳定 code，不能透传原生异常正文、URI、文件内容或 stack。

纯提取入口：`extractMaterial(bytes:, filenameHint:, limits:) → ExtractedMaterial`。结果包括纯文本、格式、实际源 SHA256、提取文本 SHA256、块定位及遗漏警告；定位偏移针对**提取文本的 UTF-16 code units**，用户校对后的草稿可以不同，来源 JSON 分开记录。

## 选择与读入

Windows 只在用户点击导入后调用已锁 file_selector 单文件选择；拿到路径后以分块 File IO 写入随机会话私有文件，先 stat 快拒但实际读入累计仍检查。文件名只作显示与格式提示，不能当目的路径，原文件不改、不移动。人验未参与时不弹主机选择器；后台测试注入合成选择输入。

Android 独立 channel `shiyu/material_import`，只使用 `ACTION_OPEN_DOCUMENT`＋`CATEGORY_OPENABLE`，单选 TXT／DOCX；不取长期 URI 权限、不添加全盘读取。用户点击才启动 picker。供应商 SIZE 只供快拒，固定小 buffer 读入到 app cache 下随机 reqid 文件，每次写入**前**检查实际总量；未知／谎报大小同样受限。超限多读至多一个检测字节即整次失败，不能返回截断文档。同步落盘后才返回 App 私有 stage 元信息；URI 不交给 Dart，读取错误不记录正文／URI。

原生上限由常量硬限制，不接受 Dart 传入任意大值绕过。仅一个活动 picker/copy worker；取消标记与可关闭 stream 生效后仍需等待旧 copy 真正退场，才允许下一次导入。ContentResolver 的 open/read 可能被供应商阻塞，不能保证 close/interrupt 立刻返回；此时保留忙碌／取消中，不无限创建线程或声称资源已释放。迟到回执只按 opaque reqid 清理本会话，不提供任意路径删除 channel。

## 解析约束

候选首轮限额为原文件20MiB、2048 entries、单 entry 实际输出16MiB、总实际输出64MiB、单 XML8MiB、文本200000码点、XML深度128、500000 events、单元素128属性。它们需典型设备／文档及超限测试后才冻结；达到限额整次拒绝并建议按章节拆分，最终长文目标仍保留，不静默截断。

ZIP 先懒读元数据，再按名称规范化、重复 part、flags、加密、方法、链接、目录数量／大小筛查；核 local/central 名称、flags、CRC／长度及合法 descriptor，冲突或重叠失败。只支持 STORE/DEFLATE，不递归解析 ZIP，不向任意路径解压。所有实际输出包括忽略的图片等也受限并校验 CRC；必要 XML 有界保留，其余可有界验证后丢弃。不先 `.content/readBytes` 再限额。

DOCX 核 `[Content_Types].xml`、根 `_rels/.rels` 的 officeDocument 关系与允许 main part；不能仅凭 PK 扩展名判 DOCX。命名空间按 URI，支持的 transitional/Strict 范围在实际结果写清；不支持的 URI 明确拒绝，不当空文件。正文／表格保持可解释顺序；图片、版式、页眉脚注、注释、跟踪删除等未提取项提供警告；外链只保留文字，不下载；DOCM／VBA 宏不支持，嵌入对象不执行、不启动 Office。

TXT 严格 UTF-8（可 BOM）、或有 BOM 的 UTF-16 LE/BE；拒奇数字节、孤立 surrogate、损坏 UTF-8 和不支持编码，不 replacement 猜译。XML 使用显式 nesting/namespace/document 校验及 namespace 注解，懒事件检查深度／数量；拒 DTD、自定义／外部实体，只用库默认五实体＋合法 numeric entity，拒无效 XML／Unicode 字符。

解析在独立 isolate；取消／超时实际 kill worker 并使会话 epoch 失效，不用 Future timeout 冒充停止计算。原始字节路径仅在 App 与 worker 内传递，公开结果不含路径。

## 草稿保存、来源与取消

1. 点击导入前处理当前 dirty 内容；一个编辑器同时只持有一个活动会话。切换输入／Store／账号／关闭后旧 preview 不回填。
2. 预览阶段仅私有 staging，尚不注册永久 ArtifactRef。用户可校对标题／文本，尚不创建草稿或学习版。
3. 用户保存时 `prepareArtifacts` 重新有界读源并核 preview SHA256；来源 JSON 再受独立 **2MiB实际编码字节硬限**。使用 `JsonUtf8Encoder` 的4096字节chunk与写入前检查sink，块列表惰性投影，不能先构造整份JSON字符串或全量编码字节再判大小。必须在源／JSON任一制品注册之前完成有界编码，超限整次 `outputTooLarge`，不截断正文或来源、不先留下明知超限的源孤儿。预算内再注册源文件 ArtifactRef 与来源JSON ArtifactRef。JSON 记录格式、parserVersion、已核实际源 hash、提取文本 hash、块定位和遗漏，不写 OS 路径。
4. await 返回后、真实 `createDraft/updateDraft` 之前再次核 owner/input/session epoch；提交阶段沿现有规则阻止返回／切换，不让旧会话写新草稿。仍用已有 `artifacts` 字段，不另建弱 Map 材料库。
5. Store 保存并回读后 `finish(materialId)` 从同 owner Store 再读，核两制品确在该草稿且制品绑定一致，才能清理临时会话。不是收到一个字符串就当保存成功。
6. 取消实际停止 worker／请求原生取消，清理仅会话 stage。若 source/JSON 已注册但草稿失败或取消，现有 Store 无制品删除事务，可能留下私有未引用制品；保留事实和重试引用，不宣称全量回滚，不盲删有效制品或用户原件。保存成功的附件不因页面退出删除。

## 本批验收

纯提取合成中文／英文／emoji／表格／命名空间／编码基线，实际输出限额与 ZIP/XML 异常矩阵；会话取消／旧回执／换 owner／保存中退出与源篡改；真实 FileStore 源制品与 JSON 回读、固定版本与重启；Widget 导入→校对→保存→确认→列表。Windows选择器人验与 Android任务自有无窗口 SAF 真实链分开留证，不能从纯测试推定四端支持。本批不调用云，不自动生成学习内容／配音／评分／分享。
