# 顶部预览提示条背景与宽度修复

2026-11-25。普通Windows与Android自验发现提示条按短文本宽度居中，左右露出黑色/透明底；Android系统状态栏区域另行区分，不把它当同一缺陷。

## 最小变化

原home的notice、SafeArea、Expanded shell原样提取为无owner/Host/Store/Player的ClientPreviewFrame。根Material绘制现有paper色，Column横向stretch，使提示表面铺满可用安全区，外侧安全区由白色表面承接。原文、12/6 padding、字号、notice更新与child资源归属保持；导航、阅读、播放、练习和底部词卡顺序未改。

## 真实回归与证据边界

| 门 | 结果 |
| --- | --- |
| 行为保持提取后的有效红 | 4失败/1通过；三尺寸短notice宽度断言红，真实raster透明RGBA与不透明白期望不符，不是编译红 |
| 最小修后作者展示回归 | 5/5，实际几何/raster、SafeArea、正文位置、notice更新与2倍字体 |
| 作者modal/导航回归 | 合计12/12，未创建原生owner/Player |
| 独立展示复核 | 三SHA与冻结相同；独立5/5 exit0、前后SHA一致，源码无P1/P2，仅展示范围准出 |
| 完整相关回归 | 单次74/74 exit0：既有62项导入/存储/关闭，加5frame、6modal、1navigator；三冻结源前后一致 |
| 静态检查 | 三文件无问题、diff检查通过；全probe原importer一条大括号info未动，不称全项目零问题 |

Windows1280×720、窄屏375×812、横屏720×375及2倍字体使用正式Flutter离屏raster，无no-test-assets，不冒充Windows普通原生窗口实测。Root首次包装命令末尾exit$c语法错，虽然日志74项绿但外层失败；原日志保留，第二轮独立日志/exit收据作为完整74项主证据。首次像素fakeAsync挂起由作者Ctrl-C结束、其单独日志被复用覆盖，仅工具会话可追溯，未虚称全部失败文件保全。

## Android当前APK实际复验

候选APK SHA `cfeeaec8137b4a0ea11a5f2bc35d6068ad9594fde8df3909097899f622634484`。在本项目无窗口/无声音/无相机的只读任务模拟器install-r，base.apk回读一致，没有clear/wipe/卸载或真实手机操作。

- 竖屏提示背景全部720像素铺满，顶部安全区白色；横屏铺满1184像素App可用区，右侧96为系统导航区；guest字体2倍后完整两行，无裁断。所有最终PNG逐张查看，背景首末行实际像素另验。
- guest字号、旋转等设置恢复原值；TXT/DOCX仍从真实系统选择器进入，提取全文、校对、保存、确认、空文件/取消无Store变化均通过。
- 同一临时运行层冷启后Store字节完全相同，两个草稿、两个固定版本、四个来源制品；原文件字节、注册表长度/SHA及sidecar摘要均通过，stage清空，当前采样错误/崩溃标记为0。
- 新只读overlay本来没有前轮三材料；没有从备份直接写Core造旧数据，不把本轮说成跨overlay升级保持。初始脚本误把cat错误当Store、选择器快捷入口未显示文件、采样及等待等私有错误均单列保留，不改产品断言求绿。

该修复未改已修Android缓存目录合同、Windows私有lease/pathGuard、Host/退出顺序、SDK/Core、权限或依赖锁。AVD与私有ADB已正常收尾并实查端口空、任务进程0；基础AVD与host证据保留。

## 仍未完成

Windows普通UI的后台foreground异常没有被这个布局变化修复。默认桌面不得再冒险复开；独立Desktop的broker/dummy代码尚在审查，未创建系统对象或运行。Windows新普通包的实际显示须等安全隔离门后验证，不能借离屏Widget/安卓截图外推。

英语生成、真实朗读、专业评分及词句复习/看板仍是独立欠交。核心方案正在审不可变快照、最终一次确认及真实资源能力，不把登记声线或fixture任务当学习闭环已通。未合并主分支、灰度或上线。
