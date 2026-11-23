# C-sdk：代码流式媒体传输与有界通道

2026-11-23。本片只新增SDK通道／传输两个模块、类型导出与作者回归，不改已验收stdio、B、Core、依赖或App UI。音频bytes由代码通过MCP pipe传输，不搬入模型上下文、日志或工具结果，不新增服务端路径／URL读取。

## 合同与事实边界

- 精确initialize、支持的版本协商、initialized通知、tools/list及必要字段检查后才ready；8个名字本身不足以认定兼容。
- Transfer借用Channel；Channel只拥有订阅、请求关联和计时状态，不关闭／杀掉借用的Process或sink。调用者在逻辑drain后处理自己拥有的资源。
- 请求25秒覆盖写入和响应；迟到／重复／未知ID会终止通道。已完整验证的ACK保留已知事实，后续输入故障仍结束通道并禁止继续data，不能反向把已提交成功改成未知。
- sourceFactory两遍读取，单64KiB组块buffer与最多30块摘要，第二遍逐块／全量摘要核对；实际source分片不等于协议分块。非法值、超限、变源不被静默截断或换业务键继续。
- 15秒仅约束可信合作式异步源无进展，不能抢占同isolate同步阻塞。读取用单活动ticket，成功／取消／超时均解除SDK引用、timer和continuation；原挂起future仅观察一次，不进drain。
- unknown按原stage／upload／receipt显式恢复，不自动重试、新delivery或新授权。取消保持sticky；begin未知无ACK id时只localStop／needsReconcile。取消后的resume可显式更换ready通道引用，但不发请求或重读源；随后再次显式abort才可重试原upload。

## 两个源码P1与原生VM失败

首版作者20组通过，但独立默认VM在transfer首个_readSource及channel末组两次原生崩溃：Windows Dart3.14优化器内部assert，exit -1073740791。旧日志与冻结源保留，不能当普通断言失败，也不以作者20绿替代该环境失败。

独立源码审查另发现：已验证ACK在flush未完成时遇EOF／重复ID／坏帧会丢失；每个source emission向同一pending取消Future追加监听，公平yield不消除累积。旧完整库固定后，独立三个ACK场景真实退出1，候选已提交却被SDK降unknown。

最小重构保留已验证ACK、终止channel；源改为单active open/read ticket。迟到provider只绑定已清空ticket，不保留transfer、iterator或assembler，不推进stage；cancel只调用一次，有界逻辑cleanup缓存，不能drain再等原未完成future。未升级SDK、未以优化开关绕行验收。

重构后作者在默认VM重跑原20组及新增4组均退出0，新增包含三个ACK故障和每遍80000空事件／变长异步List与Uint8List的真实两遍Store链。它证明当前范围在原运行时通过，不声称修复上游编译器本身或断电耐久。

## 冻结与验证

修复后的实际工作区channel SHA：`4e45f7fc612a4f0b330a1481d1e118441e743c73d0607cef5fbd4d9e9d8179ac`；transfer SHA：`e583d26e153fff60c4d3ca3e3a6f654e3156c1c379f99de70be979628591bc18`。Git行结束符规范化由公开清单另记。

| 范围 | 实际结果 |
| --- | --- |
| 作者默认VM | 原20组及新增4组通过、退出0；诊断PID不计测试 |
| 作者静态／范围 | 分析无问题，旧stdio／B关键SHA保持一致 |
| 独立修复源码复核 | 固定五SHA匹配、两个P1收口；该角色未执行Dart |
| 独立默认VM Transfer | 17/17，退出0，约81.9秒 |
| 独立默认VM Channel | 8/8，退出0，约42.5秒 |
| 独立ACK旧红回归 | 3/3，退出0，约10.7秒 |
| 修复后完整Probe静态集成 | 无问题，退出0，22.7秒；无原生运行或播放 |

独立行为终验已在默认VM下有限准出：无跳过、无原生assert，五源前后SHA一致。首组每遍80000合作式空事件（共160000）与变长源、大于一个分块的实际数据和最大30块均通过。15秒source／open及25秒silent用例为本轮真实等待，未使用模拟触发替代；监听硬边界来自定点源码复核，不将stress称为通用Heap测量。

作者真实代码pipe验证最大合法1920044B／30块、两遍分片、正常pending候选，同stdin取消到实际Bbarrier早于Material release；实际chunk／seal／submit／abort ACK被调用者过滤后显式新通道原stage恢复，ref／candidate唯一，seal／submit不重读源。所有“实际App侧”均指测试宿主中的真实Controller／FileStores，非已打包界面。

静默child、silent初始化、借用资源不close/kill、空事件公平与合作source超时分别验证；捕获计时回调与真正等待的证据分别列，不能把受控触发称实际等待15／25秒。源和取消Future超时只结束逻辑等待，不宣称取消远端Store。

## 保留记录与限制

早期Python默认GBK清理含中文脚本失败、schema元数据校验过浅及取消回执丢失后的新通道引用修订均留日志；最终无占位代码。SDK元数据拒绝用必要properties／required集合，不能因为名称齐全就开始上传。

当前不包含C3安全工厂、授权UI、候选媒体文案、原生打包／播放、人验、专业发音评测、云同步或全平台发布。SDK通过也不等于完整产品交付；四个平台范围保留，Android尚无Windows stdio等价完整链，须按实际证据分别准出。
