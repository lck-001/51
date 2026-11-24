# C3-G1-B：真实存储工厂、私有导入与关闭链

2026-11-24。本片把安全根接入App存储owner，增加受控staging、缓存生命周期和导入完整Future追踪；不实现新UI、Player、代理打包、Core Schema或依赖。Windows证据不外推Android完整MCP链。

## 实际行为

- Windows复用A lease的唯一RootLock，按同一Material→Learning→C1直接私有子根→借用Controller装配，不另开writer或悄悄降级为可用text-only工厂。媒体和原文读取仍默认false。
- 导入副本与sidecar进入已验证私有root，原选中文件ACL不改，旧Temp不扫描／迁移。staging各次await后检查退役，已建文件先登记所有权；清理不删除已登记的source artifact orphan。
- 缓存prepare与resolve共用guard、入场封门和真实tail；await后退役不再启动新mkdir／write／rename，已进入IO真实结束后才能drain。原caller预期closed不等于IO尚未结束，真实guard／I/O错误仍使lifecycle失败。
- importer先登记preview／preparing／finishing／cleaning链。nativeIdle、guard或cleanup早错也等待全部已受理工作，再报告首错；仅忽略本session内部明确身份的retirement异常，不按公共cancelled／sessionClosed代码吞错。
- 同步retire各分支隔离首错，继续封住其它入口。Bridge真实settle后才C1.close，缓存／导入／runtime等全部收尾安全后，才Learning→Material→lease锁和pins。启动失败按相同所有权反向收口。
- closeLearning／closeMaterials／releaseAuthority各自检查前置成功状态，并合并同一步在途Future，不能靠调用者顺序或重复关闭底层Store蒙混。失败保留锁，不用timeout假称真实IO完成。

## 实际验证

最终importer工作区SHA：`aeef17f7a4fb51afbc3c287a2885978366d61f92d6c105c83d3482ecc7611c98`；其它五文件与相应冻结记录一致。公开清单另记Git行结束符规范化后的blob摘要。

| 验证 | 实际结果 |
| --- | --- |
| 作者最终headless回归 | 32/32：新storage21、原importer9、provenance2，退出0 |
| 作者缓存／协调器兼容 | 22/22，退出0；受控播放Adapter，无native播放 |
| 独立最终headless QA | 31/31，单次完整退出0；六文件前后SHA一致 |
| 独立源码复核 | 原六文件及最终importer小diff复核无P1；P2 await门禁已收口，未计为运行 |
| 完整Probe静态集成 | 无编译错误，1条curly-braces info；显式no-fatal-infos检查退出0，不称No issues |

测试使用官方 `flutter test --no-pub --no-test-assets`，只执行无渲染真实FileIO；fixture通过File而非Flutter asset取得。不把该选项当Widget、字体／shader、资产bundle或原生构建验收。

独立31项覆盖同对象与默认许可、TXT/DOCX实际worker、两个artifact、草稿及清理、缓存两入口真实IO暂停退役／rename故障持锁、native及cleanup同公共错误码但不同来源、真实source artifact已提交后ACK暂停不续sidecar、单步并发sameFuture／真实Store一次关闭、close前置检查及启动失败保全。新增五个真实await门禁限定staging目录计数，retire后无后续rename／不新建不该创建的stage，原文件不变，关闭等待真实Future释放。

## 保留的红与修正

- 首个Flutter测试在加载前因Unicode路径的impellerc shader包含失败，未计行为。无渲染本组用官方no-test-assets后执行全部断言，不改SDK或依赖、不启动GUI。首次错误cwd和支架编译返回类型错均保留。
- 新五组真实红发现单步关闭并发未合并，及native／cleanup抛同public code被错误吞成drain成功。私有异常identity及inflight合并后转绿，保留旧12 pass／5 red记录。
- 源码复核P2发现staging length／stat／guard等待期间retire后仍可发后续空文件或rename；虽有原preview追踪、无早释锁，仍补齐每await后的ownership门禁，再重新冻结并独立重跑，不用旧24绿代替。
- 独立测试首轮telemetry路径、缺TXT扩展名、代理占位不存在，以及错误计入Core初始化rename、IOOverride外创建File导致length探针不触发，均只修私有harness。旧exit及日志保留；最终计数限定本session staging，文件／Store效果断言不删。
- 唯一已知静态提示为importer一处大括号样式info。为保持最终冻结一致未再改源码，明确不把有info称为零问题。

## 证据边界

独立测试在进程内使用合成目录、真实Core/FileIO和薄暂停委托；没有用户资料、系统选择器、MediaKit、Host、SystemNavigator、主界面或音频。平台就绪测试探针默认null，仅可信测试改变false／throw结果，不代替真实导入／Store权威，不进UI或MCP权限。

G2才接授权与候选媒体状态，G3才编译实际八工具proxy、组合native链与Windows包、人验。Android维持原sandbox工程范围；离线学习内容接入另微包，不能因App构建成功宣称Windows等价链。四平台总范围不变，未灰度、未发布。
