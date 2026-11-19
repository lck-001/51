# Material 注册操作与制品共用快照，有损恢复持久封门

MaterialStore 的普通 import 继续产生新随机制品；幂等能力单独由
IdempotentArtifactStore 提供。App 派生可信业务操作键，Store 仅验证严格
64小写hex语法并绑定已验证的实际完整bytes，不从cap、媒体hash或随机上传ID
派生业务身份。operation与ArtifactRef在同一个Material schema2快照提交，
不在代理、上传journal或LearningStore复制注册事实，也不承诺跨Store事务。

正常主快照完整时，提交后响应丢失可由原操作键查询/重放得到原ref。
blob rename而快照未提交留下orphan，不能猜作成功。主损坏退回较旧备份时，
可能已丢成功operation，因此必须先持久registration.hold，再恢复历史快照；
无法持久hold则不覆盖损坏现场。hold跨重启封住所有快照写和operation查询，
允许校验通过的历史读取；没有自动清除/绕过路径，不声称恢复不可恢复映射。

schema1升级先写schema2备份，再主快照，再单向marker2。原B1首次初始化
仅有主快照与marker1、没有备份，若无异常/hold/迁移残留仍是正常迁移入口；
坏/不可读备份不得当不存在。未完成迁移仅在两份旧字段/sequence完全一致且
操作映射为空时补完。旧schema reader拒绝两份schema2，但marker不能阻止
升级前已在内存且不遵守锁的旧writer，升级前必须结束旧实例。

新注册准入限制为单份2MiB、128条操作、artifact目录真实文件保留64MiB；
legacy import、未引用、孤儿及不完整残留都占后者，无法可靠计额则拒绝。
满容量的同key同bytes可只读返回，但仍遵守closed/hold/writeBlocked门禁。
这不是全Store硬配额、流式大媒体能力或无限历史保留方案，不增加GC。

验收分别覆盖作者真实合成FileIO/独立VM崩溃、独立架构与QA、既有B1及导入
消费回归；不将静态分析或本机进程崩溃测试表述为断电耐久、四端设备或用户验收。
