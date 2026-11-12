"""Draw private user feedback and an admin-only feedback workspace; no backend."""
from pathlib import Path
p=Path(__file__).resolve().parent/'build_design.py'
s=p.read_text(encoding='utf-8').replace('v0.12','v0.13')
s=s.replace('<a href="#m27" class="sectionlink">隐私资产</a></div>', '<a href="#m27" class="sectionlink">隐私资产</a><a href="#m36" class="sectionlink">帮助反馈</a></div>')
s=s.replace("'<h2>文本和音频已保留</h2>'+txt('明天的产品分享 · 任务详情','muted small')+", "'<div class=\"spread\"><h2>文本和音频已保留</h2><a class=\"small indigo\" href=\"#m36\">反馈问题</a></div>'+txt('明天的产品分享 · 任务详情','muted small')+")
css='''
#m36 .content{gap:11px}#m36 .card{padding:12px 14px}#m36 .hintfield{line-height:1.75}
#m37 .content{gap:11px}#m37 .listrow{padding:10px 0}
.feedback-metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:15px;margin:0 0 20px}
.feedback-metrics>div{background:#f6f7fc;border:1px solid #e6e9f1;padding:17px;border-radius:10px}
.feedback-metrics strong{font-size:28px;display:block;margin-top:6px}.feedback-metrics span{font-size:12px;color:#8590a7}
.feedback-columns{display:grid;grid-template-columns:1.25fr 1fr;gap:20px;align-items:start}
.feedback-table{width:100%;border-collapse:collapse;font-size:12px}.feedback-table th{font-weight:500;color:#8590a7;text-align:left;border-bottom:1px solid #e5e9f3;padding:11px 8px}
.feedback-table td{padding:15px 8px;border-bottom:1px solid #edf0f6;vertical-align:top}.feedback-table .current td{background:#f3f3ff}
.feedback-inbox{display:flex;gap:12px;align-items:center;background:#f2f2ff;padding:12px 15px;border-radius:9px;margin-bottom:18px;color:#5557d7;font-size:13px}
#d04 .deskintro{margin-bottom:18px}#d04 .card{padding:17px}#d04 .hintfield{font-size:12px}#d04 .note{font-size:11px}
'''
at=s.index("'''",s.index("CSS=r'''")+len("CSS=r'''"))
s=s[:at]+css+s[at:]
mobile='''phone('m36','帮助与反馈','帮助与反馈',
 '<div class="spread"><h2>哪里不顺手？告诉我们</h2><a class="small indigo" href="#m37">我的反馈</a></div>'+txt('建议、问题和投诉，都可以在这里提交。','muted small')+
 '<div><h3>反馈类型</h3>'+chips(['使用问题','功能建议','内容纠错','投诉申诉'])+'</div>'+
 card('描述一下问题','<div class="hintfield" style="min-height:115px">播放到一半时偶尔暂停，点重播后能继续。希望帮忙看看是什么原因。</div><p class="tiny muted">示例内容 · 可以补充操作步骤</p>','compact')+
 '<a class="btn secondary" href="#">'+icon('plus')+'选择截图（可选）</a>'+
 '<div class="checkrow"><span class="checkbox"></span><span>附带页面、系统和应用版本<br><span class="tiny muted">可先查看，不包含材料正文或录音</span></span></div>'+
 '<div class="checkrow"><span class="checkbox"></span><span>附带脱敏诊断信息（可选）</span></div>'+
 note('请勿填写密码、验证码或密钥；截图请先检查是否含私人信息。')+note('提交后可在“我的反馈”查看进度与回复。'),
 actions=btn('提交反馈','m37')+btn('返回我的','m25','secondary'))

phone('m37','我的反馈与进度','帮助与反馈',
 '<div class="spread"><h2>每条反馈，都有进展</h2>'+pill('仅本人可见','gray')+'</div>'+
 card('播放偶尔暂停','<div class="spread">'+pill('使用问题')+pill('已收到','green')+'</div>'+txt('FB-0001 · 示例编号','muted tiny')+txt('播放到一半时偶尔暂停，点重播后能继续。','small'),'compact')+
 card('处理进度',row('已收到','反馈已保存，不需要重复提交','check',pill('完成','green'))+row('待核查','等待确认问题与处理负责人','clock',pill('待处理'))+row('回复与更新','有新进展会显示在这里','bell',''),'compact')+
 card('回复方式',txt('首版仅应用内提醒。下次打开应用或反馈详情时，可以查看未读回复。','small'),'soft compact')+
 '<div class="spread small"><span class="muted">我的其他反馈</span><a class="sectionlink" href="#m36">再提一条</a></div>'+note('采纳建议不等于已经发布；完成修复时会关联实际版本。')+note('需要补充信息或问题仍存在时，可以继续反馈。'),
 actions=btn('补充说明','m36','secondary')+btn('返回我的','m25'))

'''
at=s.index("desktop('d01'")
s=s[:at]+mobile+s[at:]
desk='''desktop('d04','反馈中心 · 管理端',
 '<div class="deskintro"><div><h1>用户遇到的事，集中处理</h1><p>先核查问题，再关联改进与实际发布；不让反馈只停在收件箱。</p></div><div>'+pill('仅管理角色 · 示例','gray')+'　'+pill('应用内提醒')+'</div></div>'+
 '<div class="feedback-inbox">'+icon('bell')+'<b>6条未读反馈</b><span class="grow">提醒已进入站内收件箱；未读与待处理分开查看。</span><span>查看未读</span></div>'+
 '<div class="feedback-metrics"><div><span>待处理</span><strong>6</strong></div><div><span>处理中</span><strong>3</strong></div><div><span>待验证修复</span><strong>2</strong></div><div><span>本周新增 · 示例</span><strong>11</strong></div></div>'+
 '<div class="feedback-columns"><div>'+card('反馈列表',chips(['全部','投诉优先核查','功能建议','待验证'])+'<table class="feedback-table"><tr><th>编号/类型</th><th>反馈摘要</th><th>状态</th><th>来源</th></tr><tr class="current"><td>FB-0001<br><span class="muted">使用问题</span></td><td>播放到一半时偶尔暂停</td><td>待处理</td><td>Android<br>v0.13示例</td></tr><tr><td>FB-0002<br><span class="orange">投诉申诉</span></td><td>希望复核一次评测结果</td><td>优先核查</td><td>iPhone</td></tr><tr><td>FB-0003<br><span class="muted">功能建议</span></td><td>希望能循环选中的几句话</td><td>待评估</td><td>Windows</td></tr><tr><td>FB-0004<br><span class="muted">内容纠错</span></td><td>这一句的释义可能不合语境</td><td>处理中</td><td>macOS</td></tr></table>'+note('同类问题可以聚合，但每位用户的原始反馈和进度保留。'))+
 card('从反馈进入迭代',line('问题归属','先确认，再分配负责人')+line('迭代关联','已采纳 / 待排期 / 已发布分开')+line('完成条件','版本、复测和用户回复可追溯')+note('AI可以建议分类和摘要，不能擅自关闭投诉或承诺修复日期。'),'compact')+'</div><div>'+card('FB-0001 · 私有详情',txt('播放到一半时偶尔暂停，点重播后能继续。','small')+line('可见范围','提交人和获授权处理者')+line('页面/版本','用户选择附带后才可查看')+line('附件','无附件 · 不自动抓取原文')+'<div class="twobtn">'+btn('领取并标记处理中',None,'secondary')+btn('关联改进事项',None,'ghost')+'</div>')+
 card('给用户回复','<div class="hintfield">已收到，我们会先核对播放状态。有进展会在反馈详情更新。</div><p class="tiny muted">回复草稿 · 发送前人工确认</p>'+btn('确认后站内回复',None,'primary'))+
 card('提醒与处理纪律',line('提醒渠道','首版仅应用内')+line('紧急投诉','优先人工核查')+note('应用关闭时不承诺系统推送；提醒失败不丢反馈。')+note('涉及收费/隐私的处理不自动退款、删材料或修改账本。'),'compact')+'</div></div>',active='我的')

'''
at=s.index('PAGES.sort(')
s=s[:at]+desk+s[at:]
p.write_text(s,encoding='utf-8')
print('Added private feedback and admin workspace design')
