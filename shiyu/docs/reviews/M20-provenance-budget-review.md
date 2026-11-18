# M20 来源 JSON 编码预算修复

2026-11-18，提交前追加评审。`4039…e2b5`／`6465…358e` 的既有原生矩阵保留为历史证据；本文修复后需形成更新构建，不能把旧APK的业务流程通过扩大为本预算门槛也已通过。

## 实际问题与安全复现

旧 App `prepareArtifacts` 先注册原始来源制品，再构造所有 block Map，经 `jsonEncode` 和 `utf8.encode` 生成无独立大小限制的来源JSON。DOCX的合法长 main part 名会重复进入每个 block，压缩输入、XML和正文限额不能约束最终JSON字节数。

采用约2KiB main part 路径、1000个单字符短段的合法合成 DOCX，实际源43782字节、正文1999字符。旧实现实际生成2263128字节的JSON并返回两个 ArtifactRef；要求 `outputTooLarge` 的测试明确失败。没有制造GB级数据或执行OOM实验。

## 修复

- 来源JSON独立硬限2MiB，使用 `JsonUtf8Encoder` 的4096字节chunk逐次编码，sink在保留chunk前核实际累计字节。没有先建立整份JSON字符串或全量编码数组后再限长。
- block使用只读惰性列表投影，编码进行到该block时才建立临时Map，不在预算检查前预造全部Map。
- 原文件有界重读并核SHA后，使用已核源SHA构造来源JSON；**整个有界编码成功后**才注册来源文件和JSON制品。明知超限不先留来源孤儿。
- 超限整体返回既有 `outputTooLarge`，正文、块和来源均不截断；现有页面的拆分提示适用。Session Interface、依赖版本、原生SAF和解析输出不变。

## 实际验证与边界

整包 `flutter analyze --no-pub` 无问题。实现方App导入9项测试实际全部通过；新增回归通过真实Controller和解析worker验证上述小DOCX预览成功，但保存来源前被拒绝：真实Store manifest中 artifacts为空、无草稿、原源文件字节不变，取消后stage清空。原有普通来源保存、制品回读及重开测试保持通过。

独立QA另写并实际执行 `test/client_import_provenance_test.dart`，**2/2通过，整probe静态分析无问题**：超限输入通过公开 `prepareArtifacts` 报 `outputTooLarge`，零blob／零草稿、原源SHA不变、取消后stage清空；预算内200个长part block的多chunk来源JSON逐块／偏移／中文emoji／hash及两制品保存确认均完整。同行给予本预算门槛有限准入。这些控制接口证据与下节原生复验分开记账，不能由2/2推定全部原生平台完成。

## 更新候选的有限原生复验

新 Android debug 候选 `0.1.1+2`，153709927字节，SHA256：

`335578fba523bc3d423626cddd3eb7ab560bc874d18e022cb97b313d9f7f711b`

在重新核验归属／qemu／零账号／历史工程包白名单后的任务自有 API36 x86_64 AVD，以无窗口、静音、不接主机媒体、私有ADB5038方式实际执行 **35项标量检查，全部通过**：

- 新只读AVD无旧M20材料，明确不称升级恢复。普通原创DOCX经真实SAF选择、段落／表格／中文emoji逐字核对、guest校对标题、Save两refs、确认及App冷启均通过。
- 正常来源JSON738字节，源文件字节／来源SHA／提取文本SHA、全部5个block及UTF-16偏移和2行表格均完整，冷启仍保留1草稿／1固定版／2制品。
- 同一安全放大fixture为43782字节，SHA `1d1e5d1064b1f4f69454def676787c55af9b440fef3191e5641d24ebfeab0634`；经真实SAF预览1000短段后点Save，实际显示处理上限／拆分提示，预览1999字符保持完整。原有Store的artifacts、drafts及versions均不增，原输入SHA不变。
- 返回并明确放弃预览后，私有stage目录为空，原普通DOCX草稿／版本／制品数据完全不变。没有GB级分配或OOM试验。

首次 `am start -W` 的约10.8秒等待超时，随后真实UI XML确认正常本机预览和导航；后续以实际首帧／UI readiness核验，不把该启动请求当成功。任务包崩溃缓冲区为空，采样包日志无fatal／未处理异常／布局溢出标记。

候选min24／target36，权限与M20前批相同，没有新增存储／相机／麦克风权限。只验x86_64模拟器，不推定真机／其它ABI／Windows原生picker或Apple端通过；未知SIZE／阻塞提供者仍未真实故障注入。没有云调用或发布。

测试后按实时身份安全关闭自有AVD和私有ADB：专用端口全空、自有模拟器进程0，默认ADB／真实设备／主机界面未触碰。新候选的原始结果、UI截图及清理回执单独保存在私有`provenance-results`，旧4039／6465矩阵不覆盖。
