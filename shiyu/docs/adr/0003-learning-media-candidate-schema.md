# 外部媒体候选仍由固定候选修订原子确认，恢复不确定则持久封门

Learning媒体接收是独立LearningMediaCandidateStore能力，复用原候选审阅接口
和同Learning快照/队列。B1保持text-only、原payload hash及原delivery命名空间；
v2不能用另一个schema namespace规避同业务投递冲突。Material仍负责注册制品，
Learning从真实固定原文、精确有序英文、已注册完整制品bytes分别核验，不复制
Material操作映射，不新增跨Store事务或上传协议。

originalMedia及其来源/英文绑定/时锚是不可变审计。纯翻译改保留媒体；任何英文
或顺序/句数变化记录首次sticky失效，改回不自动重挂。matched确认复核实际源、
媒体与strict PCM/timing；invalidated可确认无可播放音频的partial版，即使旧blob
缺失仍保留ref及不可用诊断。实际source/revision/审计结构/双Store hold必须有效。
media.provenance.external完整复用文本确认上下文，音频声明仅存媒体专属字段，
两种声明逐值分开核验，不能把静音容器或用户确认当成朗读/版权认证。

候选固定修订、确认映射、新学习版和有效媒体引用一次Learning提交；反向引用
也严格验证。新媒体候选不覆盖既有partial版/句锚/进度，不创建Player或播放。
legacy手工/合成PCM继续原policy；external采用同一纯解析器的严格独立policy。

schema3备份优先迁移，保存原schema1/2归档，再primary3和marker3。旧B1候选
record不补inputVersion，缺省严格等于1，避免32MiB临界库因迁移字段膨胀失败；
v1仍拒所有media。旧writer已驻留内存不受marker控制，升级前必须结束旧实例。

退较旧备份可能丢已确认投递/版本，先持久Learning恢复hold再restore；不能持久
hold则保留损坏现场并失败。hold跨重启封住所有快照写、terminal/replay捷径、
候选查询与新播放准入；历史可验证的版本/paused checkpoint读取继续诚实降级。
不清空或猜测丢失映射，不宣称任意损坏零丢失。v2持久动作前检查两个Store门禁，
已进入真实commit的操作可以完成，后出现hold不等于跨文件回滚或取消。

本包仅证明合成FileIO/进程崩溃下的结构与权威边界；不证明断电耐久、多writer、
四端实机、英语朗读效果或用户验收，不新增云、账号、UI、上传、Player或GC。
