# C3-G1-A：Windows私有根与继承域基础

2026-11-24。本片仅新增安全根入口、内部WinAPI实现与合成目录作者测试，不打开Material／Learning Store、导入器、缓存或App。SDK、stdio、旧WindowsPrivacy.verify和RootLock源码未改。

## 合同

- 原子创建的新目录从出生即带当前用户与SYSTEM的私有安全描述符；existing路径只读验证，不通过补ACL、清目录或迁移旧资料取得可用状态。
- root与六个固定直接子根分别pin，按handle确认本地canonical路径、类型、无reparse及身份。pin请求实际目录读取权限并禁止delete sharing，不仅查询属性。
- 严格protected P与有效inheritedPrivate分开。目录还须OI＋CI传播，flags仅允许OI／CI／ID，拒绝IO-only、NP、额外主体、非完整权限；中间目录也须保证后续文件／目录创建私密。旧verify原义不弱化。
- RootLock在业务布局写入前取得，六子根和后代审核成功后才CREATE_NEW布局marker、flush并回读。marker不是业务恢复权威，不代替锁、身份或权限验证。
- 未知非空无marker、部分布局、宽权限或不能证明安全的existing目录只读失败，保留内容和ACL；并发初始化可能保守拒绝，不接管其它attempt。
- lease拥有本次锁与pins。close先成功释放RootLock，再收口全部pins；真实writer／Store的关闭必须由后续工厂在此之前完成。本片没有假装已证明App关停。

## 作者证据与原失败

作者最终10组真实目录行为通过，退出0；一行VM PID诊断不计测试。整包分析无问题、差异检查通过。实际包含原子root／六子根权限、普通继承只读分类与strict P负例、root rename／空child delete保护、profile重开、无传播和宽／未知布局拒绝、第二真实VM锁冲突、reparse与深度边界，失败前后合成payload／SDDL／marker／目录项保全。

首版仅以READ_CONTROL／READ_ATTRIBUTES持handle，空child仍可被删除，真实测试失败；补FILE_LIST_DIRECTORY／READ_DATA后，实际rename和delete拒绝。existing root重开仅依据CreateDirectoryW错误码的分支也曾失败，后改为现存真实目录先只读验证、创建竞态失败只核真实existing/no-reparse再验证，绝不按失败码任意放行或重设ACL。

作者另有TEMP短别名与canonical长路径的私有fixture guard误判；仅让测试母目录与目标先核无reparse再OS canonical化，不放宽生产边界。上述失败均保留。

## 固定源码与独立状态

实际验收implementation SHA：`7d358a928cd39ef7096e36c4d25c28aa04240435a10c225660ac3759e4179210`。三文件冻结，Git行结束符与实际blob摘要由公开清单另记。

独立架构已核三SHA并只读复核，无剩余阻断P1；未自行执行Dart，不计为行为通过。

独立行为有限准出采用同一三SHA下的两类实际证据：第二轮其余18组PASS，整轮因私有pin错误码探针期望而exit1；随后只复跑最终pin-case退出0、前后SHA相同。不声称一次19/19全绿，不覆盖原失败历史，也不重复已过8192边界。

最终pin以Native BOOL和errno分别记录：持lease时root rename、emptychild rename／delete均返回BOOL0、errno32，原名存在而目标不存在，所有ACL／bytes及parent ACL不变；lease.close后锁不再持有，同参数同Native API三项均BOOL1成功。首探针首次lazy lookup读取GetLastError覆写原码0，不能把诊断0解读为rename已成功。

独立已过范围包括ordinary inherited分类／strictP不弱化、合法profile只读重开、无OICI／IO／NP／extraACE、未知非空／部分布局、reparse／alias、错锁、第二真实VM锁冲突、深度与8192＋1入口门、marker失败保全。原内容／ACL／目录项保全是实际断言，不以异常字符串代替。

当前独立首轮的固定错误码、读取持有锁文件、sentinel顺序等私有探针问题均保留日志，只作精确支架修正；原有效拒绝、close后正对照及原内容／ACL保全断言不削。

## 范围限制

所有操作限任务新建目录；不修改用户AppData、旧Temp、用户原资料或系统设置，没有界面／音频／摄像头／麦克风。未声称Windows证据等价Android、iPhone或Mac。

后续G1-B才复用lease.rootLock装配同M／L／C1／借用Controller、安全staging、缓存guard／retire／drain，以及启动失败和关闭顺序；授权UI、代理打包、实际播放和人工体验另阶段。
