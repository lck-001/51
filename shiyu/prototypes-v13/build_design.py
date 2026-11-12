"""Author static, editable design canvases only. No product behavior or network."""
from pathlib import Path
import json, html

ROOT=Path(__file__).resolve().parent
ROOT.mkdir(exist_ok=True)
PAGES=[]
ICONS={
 'book':'M4 4h7c2 0 3 1 3 2v15c0-2-2-3-4-3H4z M14 6c0-1 1-2 3-2h5v15h-5c-2 0-3 1-3 2',
 'folder':'M3 7h7l2 2h10v12H3z M3 7V4h7l2 3',
 'plus':'M12 4v16 M4 12h16','share':'M18 6l-12 6 12 6 M6 12h14',
 'user':'M8 7a4 4 0 1 0 8 0 4 4 0 1 0-8 0 M4 22v-3a8 8 0 0 1 16 0v3',
 'mic':'M8 5a4 4 0 0 1 8 0v7a4 4 0 0 1-8 0z M5 10v2a7 7 0 0 0 14 0v-2 M12 19v4 M8 23h8',
 'play':'M8 4l13 8-13 8z','volume':'M3 9h4l5-5v16l-5-5H3z M16 8a6 6 0 0 1 0 8 M19 4a11 11 0 0 1 0 16',
 'file':'M5 2h10l5 5v15H5z M15 2v6h5 M8 12h9 M8 16h7',
 'check':'M4 12l5 5L21 5','chev':'M8 5l7 7-7 7','back':'M15 4l-8 8 8 8',
 'lock':'M5 10h14v12H5z M8 10V6a4 4 0 0 1 8 0v4',
 'camera':'M3 7h12v14H3z M15 11l7-3v12l-7-3',
 'clock':'M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18 M12 7v6l4 2',
 'search':'M3 10a7 7 0 1 0 14 0 7 7 0 1 0-14 0 M15 15l7 7',
 'cloud':'M7 18H5a5 5 0 0 1-1-10 8 8 0 0 1 15-1 5 5 0 0 1 0 11h-2 M12 12v11 M8 16l4-4 4 4',
 'spark':'M12 2l3 7 7 3-7 3-3 7-3-7-7-3 7-3z',
 'wave':'M2 10v4 M6 6v12 M10 2v20 M14 7v10 M18 4v16 M22 9v6',
 'edit':'M3 17l12-12 5 5L8 22H3z M15 5l3-3 5 5-3 3',
 'info':'M12 2a10 10 0 1 0 0 20 10 10 0 1 0 0-20 M12 10v7 M12 6v1',
 'download':'M12 2v14 M7 11l5 5 5-5 M3 17v5h18v-5',
 'loop':'M4 8h14l-4-4 M20 16H6l4 4 M18 8l3 3 M6 16l-3-3',
 'bell':'M5 17h14l-2-4V8a5 5 0 0 0-10 0v5z M10 21h4',
 'chart':'M4 22V12h4v10 M11 22V3h4v19 M18 22V8h4v14',
 'stop':'M6 6h12v12H6z','settings':'M4 6h16 M4 12h16 M4 18h16 M8 3v6 M16 9v6 M10 15v6'
}
def icon(name, cls=''):
 return f'<svg class="ico {cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="{ICONS.get(name,ICONS["file"])}"/></svg>'
def btn(text,to=None,kind='primary',ic=None):
 return f'<a class="btn {kind}" href="#{to or ""}">{icon(ic) if ic else ""}{text}</a>'
def pill(text,cls=''):
 return f'<span class="pill {cls}">{text}</span>'
def chips(items,active=0):
 return '<div class="chips">'+''.join(f'<span class="chip {"selected" if i==active else ""}">{x}</span>' for i,x in enumerate(items))+'</div>'
def card(title,body='',cls=''):
 return f'<section class="card {cls}"><h3>{title}</h3>{body}</section>'
def row(title,sub='',ic='file',tail='›',cls=''):
 return f'<div class="listrow {cls}"><span class="iconbox">{icon(ic)}</span><div class="grow"><b>{title}</b>{f"<small>{sub}</small>" if sub else ""}</div><span class="tail">{tail}</span></div>'
def note(text,cls=''):
 return f'<div class="note {cls}">{icon("info")}<span>{text}</span></div>'
def txt(text,cls=''):
 return f'<p class="{cls}">{text}</p>'
def line(label,value,cls=''):
 return f'<div class="dataline {cls}"><span>{label}</span><b>{value}</b></div>'
def bar(pct=38):
 return f'<div class="bar"><i style="width:{pct}%"></i></div>'
def waveform():
 vals=[12,25,19,40,32,54,46,24,38,62,42,30,50,20,35,18,12,22,14]
 return '<div class="waveform">'+''.join(f'<i style="height:{v}px"></i>' for v in vals)+'</div>'
def nav(active='学习'):
 ns=[('学习','book','m02'),('材料','folder','m03'),('添加','plus','m04'),('分享','share','m20'),('我的','user','m25')]
 return '<nav class="nav">'+''.join(f'<a href="#{dest}" class="{"active" if label==active else ""} {"add" if label=="添加" else ""}">{icon(ic)}<span>{label}</span></a>' for label,ic,dest in ns)+'</nav>'
def player(time='01:24',total='04:20'):
 return f'<div class="player">{bar(33)}<div class="spread muted tiny"><span>{time}</span><span>{total}</span></div><div class="controls"><span>ı◀</span><span class="round">{icon("play")}</span><span>▶ı</span></div></div>'
def phone(id,title,group,body,header=None,active=None,actions='',cls='',extra=''):
 head=f'<header class="phonehead"><span>{icon("back") if not active else "拾语"}</span><b>{header or title}</b><span class="small">{"⌕" if active else "···"}</span></header>'
 if active: head=f'<header class="phonehead"><b>{header or title}</b><span class="muted">{icon("search")}</span></header>'
 content=f'<section id="{id}" class="screen phone {cls}"><div class="status"><b>9:41</b><span>▴▴  ▰</span></div>{head}<main class="content">{body}</main>{f"<footer class=actions>{actions}</footer>" if actions else ""}{nav(active) if active else ""}<div class="homeindicator"></div>{extra}</section>'
 PAGES.append(dict(id=id,title=title,group=group,width=390,height=844,path=f'screens/{id}.png',html=content))
def desktop(id,title,body,active='材料'):
 links=''.join(f'<div class="sideitem {"chosen" if x==active else ""}">{icon(ic)}{x}</div>' for x,ic in [('学习','book'),('材料','folder'),('分享','share'),('我的','user')])
 content=f'<section id="{id}" class="screen desktop"><aside class="sidebar"><div class="brand">{icon("book")}<b>拾语</b></div><p>学自己的内容，说自己的话。</p>{btn("添加学习材料","m04",ic="plus")}{links}<div class="sidefoot">{row("用量与预算", "本月用量可查看", "chart", "")}{row("隐私与资产", "私有内容由你管理", "lock", "")}</div></aside><main class="deskmain"><header class="deskhead"><span>{title}</span><div><span class="desksearch">{icon("search")}搜索我的材料与词句</span><span class="avatar">承</span></div></header>{body}</main></section>'
 PAGES.append(dict(id=id,title=title,group='桌面端布局',width=1440,height=960,path=f'screens/{id}.png',html=content))

CSS=r'''
*{box-sizing:border-box}html{scroll-behavior:auto}body{margin:0;color:#172641;background:#eef1f6;font:14px/1.55 "Segoe UI","Microsoft YaHei UI","Microsoft YaHei",sans-serif}a{color:inherit;text-decoration:none}h1,h2,h3,p{margin:0}h1{font-size:26px;line-height:1.35;letter-spacing:-.4px}h2{font-size:23px;line-height:1.4;letter-spacing:-.4px}h3{font-size:16px;line-height:1.45;margin-bottom:10px}p{margin:8px 0}small,.small{font-size:12px}.tiny{font-size:11px}.muted{color:#8590a7}.indigo{color:#5557d7}.green{color:#257d65}.orange{color:#9c641d}.bold{font-weight:650}.grow{flex:1;min-width:0}.spread{display:flex;justify-content:space-between;align-items:center;gap:10px}.center{text-align:center}.ico{width:20px;height:20px;flex-shrink:0;vertical-align:middle}.galleryhead{max-width:1680px;margin:44px auto 28px;padding:0 34px}.galleryhead h1{font-size:36px}.galleryhead p{color:#78869c;margin-top:12px}.toc{display:flex;gap:10px;flex-wrap:wrap;margin-top:20px}.toc a{background:white;border:1px solid #d9dfeb;border-radius:8px;padding:7px 12px}.gallery{max-width:1740px;margin:auto;padding:0 34px 50px}.grouphead{font-size:23px;margin:45px 0 24px}.grid{display:flex;flex-wrap:wrap;gap:26px;align-items:flex-start}.frame{margin:0 0 10px}.caption{display:flex;gap:12px;align-items:center;color:#79869b;font-size:13px;margin-bottom:12px}.caption b{color:#172641;font-size:15px}.screen{position:relative;background:#fff;color:#172641;overflow:hidden;flex:none}.phone{width:390px;height:844px;border:1px solid #dce1ec;border-radius:25px;display:flex;flex-direction:column}.status{height:37px;padding:13px 23px 0;display:flex;justify-content:space-between;font-size:12px;flex:none}.phonehead{height:58px;padding:12px 21px;display:flex;justify-content:space-between;align-items:center;flex:none}.phonehead>b{font-size:23px;letter-spacing:-.4px}.phonehead>b:not(:first-child){font-size:17px}.phonehead>span{width:28px}.phonehead .small{text-align:right}.content{flex:1;min-height:0;padding:10px 21px 12px;overflow:hidden;display:flex;flex-direction:column;gap:13px}.content>h2{margin:3px 0 0}.content>p{margin:0}.card{border:1px solid #e0e5ef;border-radius:13px;padding:15px;background:#fff;flex:none}.card.soft{background:#f5f5ff;border-color:#e9e9fc}.card.flat{border:0;padding:10px 0}.card.compact{padding:12px 14px}.card.dark{background:#202e4c;color:#fff;border:none}.card.warning{background:#fff8ed;border-color:#f3e1c3}.card h3:last-child{margin-bottom:0}.btn{height:44px;min-height:44px;border-radius:9px;padding:9px 14px;display:flex;gap:8px;justify-content:center;align-items:center;font-size:14px;font-weight:650;border:1px solid transparent;line-height:1.3}.btn.primary{background:#5557d7;color:#fff}.btn.secondary{border-color:#d8deec;background:#fff;color:#364865}.btn.ghost{background:#f3f4fb;color:#5557d7}.btn.disabled{background:#e4e7ee;color:#8994a8}.btn.danger{border-color:#ecd7d6;color:#a0524d;background:white}.btn.smallbtn{height:34px;min-height:34px;font-size:12px;padding:7px 9px}.btn:focus-visible{outline:3px solid #b6b4f4;outline-offset:3px}.actions{padding:9px 21px 9px;display:flex;flex-direction:column;gap:9px;flex:none;background:white}.twobtn{display:flex;gap:10px}.twobtn>*{flex:1}.note{display:flex;align-items:flex-start;gap:7px;color:#7f8aa0;font-size:11px;line-height:1.65}.note .ico{width:14px;height:14px;margin-top:2px}.note.warning{color:#9c641d}.note.good{color:#257d65}.pill{display:inline-flex;align-items:center;gap:6px;background:#f2f3fc;color:#6268bc;border-radius:6px;padding:3px 7px;font-size:11px;line-height:1.5}.pill.green{color:#257d65;background:#edf8f2}.pill.orange{color:#a56f24;background:#fff4e3}.pill.gray{color:#8691a6;background:#f1f3f7}.chips{display:flex;gap:7px;flex:none}.chip{padding:6px 9px;border:1px solid #e1e5ef;border-radius:7px;color:#8190a6;font-size:12px;flex:1;text-align:center;white-space:nowrap}.chip.selected{color:#5557d7;border-color:#cfcef9;background:#f0efff;font-weight:650}.listrow{display:flex;gap:11px;align-items:center;padding:13px 0;border-bottom:1px solid #edf0f5}.listrow:last-child{border-bottom:0}.listrow b{font-size:14px;display:block}.listrow small{display:block;color:#8b96a9;margin-top:4px;font-size:11px}.iconbox{display:flex;align-items:center;justify-content:center;width:35px;height:39px;background:#f4f5fc;color:#6772a7;border-radius:8px;flex:none}.tail{font-size:13px;color:#9aa4b6}.nav{height:70px;display:flex;padding:8px 7px 4px;border-top:1px solid #eef0f5;flex:none;background:white}.nav a{flex:1;text-align:center;display:flex;align-items:center;flex-direction:column;color:#9aa4b6;font-size:10px;gap:5px}.nav .ico{width:22px;height:22px}.nav .active{color:#5557d7}.nav .add .ico{background:#5557d7;border-radius:9px;color:white;width:36px;height:29px;padding:4px}.homeindicator{height:12px;position:relative;flex:none}.homeindicator:after{content:"";position:absolute;left:132px;bottom:5px;background:#172641;width:124px;height:4px;border-radius:4px}.bar{height:4px;background:#e9ebf6;border-radius:4px;overflow:hidden;margin:9px 0}.bar i{height:100%;display:block;background:#6260dd;border-radius:4px}.player{padding:7px 0}.controls{display:flex;align-items:center;justify-content:center;gap:48px;margin-top:13px;color:#52627e;font-size:18px}.round{width:49px;height:49px;border-radius:50%;background:#5557d7;color:#fff;display:inline-flex;align-items:center;justify-content:center}.round.large{width:76px;height:76px}.round.large .ico{width:30px;height:30px}.round.light{background:#f0f0ff;color:#6260dd}.waveform{display:flex;gap:4px;justify-content:center;align-items:center;height:78px;color:#696cda}.waveform i{width:4px;background:currentColor;border-radius:2px;display:block}.recordarea{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;padding:18px 0}.dataline{display:flex;justify-content:space-between;gap:16px;align-items:center;padding:8px 0;font-size:12px}.dataline span{color:#8590a7}.dataline b{font-weight:600;text-align:right}.bigmetric{font-size:32px;line-height:1.1;font-weight:700;letter-spacing:-.6px}.metrics{display:flex;gap:12px}.metrics>div{flex:1}.metrics small{color:#8b96a9;display:block;margin-top:7px;font-size:11px}.metrics>div+div{border-left:1px solid #e6e9f1;padding-left:15px}.english{font-family:"Segoe UI",Arial,sans-serif;font-size:22px;line-height:1.55;letter-spacing:-.3px}.english.large{font-size:26px;line-height:1.45;font-weight:650}.translation{font-size:13px;color:#8b96aa;margin-top:8px;line-height:1.65}.sentence{padding:7px 9px}.sentence.current{background:#f1f0ff;border-radius:10px}.sentence.current .english{color:#5757d4;font-weight:600}.selectedword{background:#dbd9ff;color:#5351cf;padding:0 3px;border-radius:4px}.wordtitle{font-size:27px;font-weight:700;line-height:1.3}.choice{display:flex;align-items:center;gap:12px;border:1px solid #dfe4ef;border-radius:10px;padding:12px 13px;min-height:57px;margin-top:10px;font-size:15px;line-height:1.45}.choice.on{border-color:#8b87eb;background:#f4f3ff}.radio{width:17px;height:17px;border:1.5px solid #a9b2c4;border-radius:50%;display:block;flex:none}.choice.on .radio{border:5px solid #5a59d9}.choice .listen{border-left:1px solid #e2e5ef;padding-left:10px;color:#6564da}.choice .listen .ico{width:21px;height:21px}.questionaudio{text-align:center;background:#f4f3ff;border-radius:13px;padding:20px 14px}.questionaudio h3{margin:9px 0 3px}.taskhead{display:flex;justify-content:space-between;font-size:11px;color:#8c97aa}.taskhead b{color:#6468b6;font-weight:600}.hintfield{padding:13px;border:1px solid #d9dff0;border-radius:9px;background:#fbfcff;font-size:14px;line-height:1.7}.miniicon{width:15px;height:15px}.spacer{flex:1}.divider{height:1px;background:#e9edf3;margin:3px 0}.sheetphone .veil{position:absolute;inset:37px 0 12px;background:rgba(26,37,60,.32)}.sheet{position:absolute;bottom:12px;left:0;right:0;background:white;border-radius:20px 20px 0 0;padding:18px 21px 18px}.sheet .handle{height:4px;width:34px;background:#d6dbe7;border-radius:4px;margin:-6px auto 18px}.sheet h2{font-size:21px}.sheet .listrow{padding:17px 0}.sheet .iconbox{height:42px;width:42px}.sheet .btn{margin-top:12px}.thumb{background:#243251;border-radius:10px;color:white;padding:17px;text-align:center;overflow:hidden}.thumb .waveform{height:53px;color:#8586df}.thumb p{font-size:14px;font-weight:550}.thumb .spread{font-size:10px;color:#cad0e2}.tagrow{display:flex;gap:7px;flex-wrap:wrap}.checkrow{display:flex;gap:9px;align-items:flex-start;font-size:12px;line-height:1.6}.checkbox{width:16px;height:16px;border:1px solid #c6cddc;border-radius:4px;flex:none;margin-top:2px}.checkbox.checked{background:#5a59d9;border-color:#5a59d9;color:#fff;text-align:center;font-size:11px}.toggle{height:18px;width:33px;background:#d9dee9;border-radius:10px;display:inline-block;position:relative;flex:none}.toggle:before{content:"";position:absolute;width:14px;height:14px;background:white;left:2px;top:2px;border-radius:50%}.toggle.on{background:#6260d9}.toggle.on:before{left:17px}.chartbars{display:flex;align-items:flex-end;justify-content:space-between;height:95px;padding:8px 4px 0;border-bottom:1px solid #edf0f6}.chartbars i{display:block;width:22px;background:#d1d3f1;border-radius:3px 3px 0 0}.chartbars i:last-child{background:#6463d9}.chartlabels{display:flex;justify-content:space-between;color:#9aa4b6;font-size:10px;padding:6px 7px 0}.trend{width:100%;height:47px}.desktop{width:1440px;height:960px;border:1px solid #dce1ec;display:flex;border-radius:15px}.sidebar{width:226px;border-right:1px solid #e6eaf2;padding:32px 20px;background:#fcfcff;flex:none;display:flex;flex-direction:column}.brand{display:flex;gap:12px;align-items:center;font-size:27px;margin-bottom:8px}.brand .ico{width:28px;height:28px;color:#5358c8}.sidebar>p{font-size:11px;color:#8994a9;margin-bottom:28px}.sidebar>.btn{margin-bottom:30px}.sideitem{padding:14px 16px;margin-bottom:9px;display:flex;align-items:center;gap:12px;border-radius:8px;color:#8793aa;font-size:15px}.sideitem.chosen{background:#ecebff;color:#5557d7;font-weight:600}.sidefoot{margin-top:auto}.sidefoot .listrow{padding:12px 0}.sidefoot .listrow b{font-size:12px}.deskmain{flex:1;min-width:0;padding:0 36px 30px;background:#fff}.deskhead{height:96px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #e8ecf4;margin-bottom:28px;font-weight:650;font-size:22px}.deskhead>div{display:flex;align-items:center;gap:24px}.desksearch{font-size:12px;font-weight:400;color:#a0a9ba;display:flex;gap:10px;align-items:center}.avatar{border-radius:50%;background:#f0effc;color:#6565b6;width:34px;height:34px;display:flex;align-items:center;justify-content:center;font-size:13px}.deskintro{display:flex;justify-content:space-between;align-items:center;margin:0 0 25px}.deskintro h1{font-size:28px}.deskintro p{color:#8995ab;font-size:13px}.deskgrid{display:grid;gap:22px}.deskgrid.two{grid-template-columns:minmax(0,1.25fr) minmax(0,1fr)}.deskgrid.three{grid-template-columns:210px minmax(0,1fr) 288px;gap:22px}.deskgrid.equal{grid-template-columns:repeat(2,minmax(0,1fr))}.deskgrid .card{padding:22px}.deskgrid h3{font-size:17px}.docpreview{height:235px;border:1px solid #e2e7f0;background:#f9fafc;padding:24px;font-size:14px;line-height:1.9;border-radius:8px}.docpreview h3{margin-bottom:18px}.docline{height:7px;background:#e2e6ed;margin:12px 0;border-radius:3px}.highlight{background:#fff0cb;border-radius:3px;padding:1px 3px}.deskbig .english{font-size:27px}.deskbig .sentence{padding:17px 14px}.deskbig .translation{font-size:14px}.deskmetric{display:flex;gap:18px;margin:20px 0 24px}.deskmetric>div{flex:1;padding:20px 23px;background:#f8f9fd;border:1px solid #e5e9f2;border-radius:12px}.deskmetric small{display:block;color:#8b96ab;margin-top:9px}.deskmetric .bigmetric{font-size:38px}.desktable{width:100%;border-collapse:collapse;font-size:12px}.desktable td,.desktable th{text-align:left;border-bottom:1px solid #edf0f6;padding:13px 7px}.desktable th{font-weight:500;color:#8b96aa}.desknotice{display:flex;justify-content:space-between;gap:15px;padding:13px 16px;background:#f5f5ff;border:1px solid #e7e6fa;border-radius:8px;margin:16px 0;color:#686cb6;font-size:12px}.sectionlink{font-size:12px;color:#6264cb}.endnote{font-size:12px;color:#8995ab;margin:18px 0}.desktop .chartbars{height:150px}.desktop .chartbars i{width:34px}.desktop .chartlabels{font-size:12px}.desktop .metrics .bigmetric{font-size:35px}.desktop .note{font-size:12px}.desktop .hintfield{font-size:13px}.desktop .dataline{font-size:13px}
 #m02 .content{gap:10px}
 #m21 .thumb{padding:14px 18px!important;flex-shrink:0}
 #m21 .thumb .waveform{height:42px}
 #m21 .thumb .waveform i{max-height:38px}
 #m21 .thumb p{margin:6px 0}
 #m25 .content{gap:10px}
 #m25 .chartbars{height:60px}
 #m25 .chartbars i{max-height:47px}
 #m26 .content{gap:9px}
 #m26 .card{padding:12px 14px}
 #m26 .dataline{padding:7px 0}

#m11 .content{gap:10px}#m11 .sentence{padding:5px 8px}#m11 .player{padding:2px 0}
.lookup-discovery{border:1px solid #c9c8f3;background:#f6f5ff;border-radius:10px;padding:11px 12px;flex:none}
.lookup-discovery .lookupword{font-size:17px;font-weight:700}.lookup-discovery .spread+div{margin-top:6px}
.lookup-discovery .lookupmeaning{font-size:12px;color:#68758d;margin-top:4px}
.lookup-sheet{position:absolute;bottom:12px;left:0;right:0;z-index:3;border-top:1px solid #d7dcec;border-radius:22px 22px 0 0;background:#fff;padding:10px 21px 14px;box-shadow:0 -8px 25px #1d2d4910;display:flex;flex-direction:column;gap:12px}
.lookup-handle{width:36px;height:4px;border-radius:3px;background:#d5d9e6;margin:0 auto 2px}
#m12 .content{background:#f8f9fc}#m12 .lookup-sheet .card{margin:0}#m12 .lookup-sheet .btn{min-height:40px;height:40px}
.camera-preview{height:174px;border-radius:12px;background:#202e4c;position:relative;overflow:hidden;flex:none;color:#fff}
.camera-preview .preview-badge{position:absolute;top:9px;left:10px;font-size:10px;background:#ffffff20;padding:3px 7px;border-radius:5px}
.camera-preview svg{width:100%;height:126px;position:absolute;bottom:27px;left:0}
.camera-preview .preview-caption{position:absolute;bottom:9px;width:100%;text-align:center;font-size:12px;color:#f6f7ff;line-height:1.5}
.camera-preview.small-preview{height:145px}.camera-preview.small-preview svg{height:108px;bottom:22px}
#m20 .content{gap:10px}#m21 .content{gap:10px}#m21 .recordarea{gap:7px;padding:4px 0}#m21 .recordarea .round.large{height:62px;width:62px}
#m21 .recordarea .round.large .ico{width:27px;height:27px}#m21 .card{padding:10px 13px}

#m11 .content,#m12 .content{padding:0;gap:0;background:#fff;overflow:hidden}
.reader-options{padding:6px 21px 10px;flex:none}.reader-options .chips{margin-top:10px}
.reader-article{flex:1;min-height:0;overflow-y:auto;padding:0 21px 12px;scrollbar-width:thin;scrollbar-color:#d2d7e8 transparent}
.reader-article .reading-paragraph{padding:10px 0 13px;margin:0;border-bottom:1px solid #f0f1f6}
.reader-article .english{font-size:18px;line-height:1.6;margin:0}.reader-article .translation{font-size:12px;line-height:1.7;margin-top:5px}
.reader-article .read-current .english{color:#5557d7;font-weight:600}.reader-article .read-current{border-left:3px solid #b9b5f5;padding-left:10px}
.reader-article .article-meta{display:flex;justify-content:space-between;font-size:10px;color:#8793a9;margin:2px 0 4px}
.dictionary-dock{flex:none;background:#f6f6ff;border:1px solid #dedff2;border-radius:17px 17px 0 0;padding:7px 20px 11px;display:flex;flex-direction:column;gap:5px}
.dictionary-dock .grabber{height:4px;width:38px;background:#c9cde4;border-radius:3px;margin:0 auto 1px}
.dictionary-dock .dock-label{font-size:11px;color:#67708d}.dictionary-dock .dock-label b{color:#404d70}
.dictionary-dock .dock-word{font-size:19px;font-weight:700}.dictionary-dock .dock-pron{font-size:11px;color:#8691a9;margin-left:7px}
.dictionary-dock .dock-meaning{font-size:12px;color:#57667f}.dictionary-dock .dock-icon{display:flex;gap:14px;color:#6261d9;align-items:center}
.dictionary-dock.expanded{gap:9px;padding-bottom:12px}.dictionary-dock .dock-example{border-top:1px solid #e1e3f0;padding-top:9px;font-size:13px;line-height:1.5}
.dictionary-dock .dock-example small{display:block;font-size:11px;color:#8892a6;margin-top:4px}
.dictionary-dock .dock-actions{display:flex;gap:10px}.dictionary-dock .dock-actions>*{flex:1}
.reader-controls{flex:none;padding:8px 21px 10px;background:#fff;border-top:1px solid #e9ebf4}
.reader-controls .bar{margin:3px 0 6px}.reader-controls .controls{margin-top:8px;gap:50px}.reader-controls .round{height:42px;width:42px}
.reader-controls .twobtn{margin-top:9px}.reader-controls .btn{height:40px;min-height:40px;font-size:13px}

.dictionary-dock{position:relative;padding:8px 20px 9px;gap:1px;border-radius:12px 12px 0 0}
.dictionary-dock:before{content:"";position:absolute;top:3px;left:calc(50% - 15px);width:30px;height:3px;background:#cbd0e7;border-radius:3px}
.dictionary-dock .dock-word{font-size:17px}.dictionary-dock .dock-pron{font-size:11px;margin-left:6px}
.dictionary-dock .dock-toprow{min-height:28px}.dictionary-dock .dock-icon{gap:13px}.dictionary-dock .dock-icon .ico{width:19px;height:19px}
.dictionary-dock .dock-bottomrow{font-size:12px;line-height:1.6;min-height:20px;color:#64718a}
.dictionary-dock .dock-bottomrow a{font-size:11px;white-space:nowrap}
.dictionary-dock.expanded{padding:10px 20px;gap:7px}.dictionary-dock .dock-example{padding-top:7px}
.reader-controls{border-top:1px solid #edf0f5;padding-bottom:10px}

#m36 .content{gap:11px}#m36 .card{padding:12px 14px}#m36 .hintfield{line-height:1.75}
#m37 .content{gap:7px}#m37 .listrow{padding:8px 0}#m37 .card{padding:10px 14px}
.feedback-metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:15px;margin:0 0 20px}
.feedback-metrics>div{background:#f6f7fc;border:1px solid #e6e9f1;padding:17px;border-radius:10px}
.feedback-metrics strong{font-size:28px;display:block;margin-top:6px}.feedback-metrics span{font-size:12px;color:#8590a7}
.feedback-columns{display:grid;grid-template-columns:1.25fr 1fr;gap:20px;align-items:start}
.feedback-table{width:100%;border-collapse:collapse;font-size:12px}.feedback-table th{font-weight:500;color:#8590a7;text-align:left;border-bottom:1px solid #e5e9f3;padding:11px 8px}
.feedback-table td{padding:15px 8px;border-bottom:1px solid #edf0f6;vertical-align:top}.feedback-table .current td{background:#f3f3ff}
.feedback-inbox{display:flex;gap:12px;align-items:center;background:#f2f2ff;padding:12px 15px;border-radius:9px;margin-bottom:18px;color:#5557d7;font-size:13px}
#d04 .deskintro{margin-bottom:18px}#d04 .card{padding:17px}#d04 .hintfield{font-size:12px}#d04 .note{font-size:11px}
#d04 .deskintro{margin-bottom:12px}#d04 .deskintro p{margin-top:5px}
#d04 .feedback-inbox{padding:8px 13px;margin-bottom:12px}#d04 .feedback-metrics{margin-bottom:14px}
#d04 .feedback-metrics>div{padding:10px 15px}#d04 .feedback-metrics strong{margin-top:3px}
#d04 .card{padding:12px 15px}#d04 .dataline{padding:5px 0}#d04 .feedback-table td{padding:10px 8px}
#d04 .card h3{margin-bottom:7px}#d04 .hintfield{padding:10px 12px}
'''

# Materials and first experience.
phone('m01','第一次打开','开始与材料',
 '<div style="padding:42px 0 22px">'+icon('book')+'</div><h1>想学什么，<br>就从什么开始。</h1>'+txt('一个故事、一份演讲稿，<br>或今天想说的几句话。','muted')+
 card('带进来，慢慢说熟',row('添加你自己的内容','文档、照片、文字、链接或口述','folder','')+row('听懂，再试着接话','英语上、中文下，帮助随时可用','volume','')+row('看见一点点变化','回听过去的自己，记录真实进步','chart',''))+
 note('材料默认仅自己可见。无需先连接工作账号。'),header='拾语',active='学习',actions=btn('添加第一份材料','m04',ic='plus'))

phone('m02','学习首页与教练','开始与材料',
 '<h2>今天，学一点自己的内容</h2>'+txt('从自己的材料开始，慢慢说熟。','muted small')+
 card('昨天的工作总结',txt('第2 / 4节 · 工作进展','muted small')+bar(36)+btn('继续听读','m11',ic='play'))+
 card('学习教练 · 帮我安排',txt('按当前材料、方便的时间来练。','muted small')+txt('先选个表达，再试着接一句话。','small')+btn('安排今天的小回合','m31',ic='spark'),'soft')+
 '<div class="spread"><b>也可以自己选</b><a class="sectionlink" href="#m15">直接开始复习</a></div>'+btn('口语练习 · 自选时长','m18','secondary','mic')+
 '<div class="spread"><b>本周进步</b><a class="sectionlink" href="#m25">查看看板</a></div><div class="metrics"><div><b class="bigmetric">86</b><small>练习分钟</small></div><div><b class="bigmetric">18</b><small>主动开口分钟</small></div></div>',header='拾语',active='学习')

phone('m03','我的材料','开始与材料',
 chips(['全部','最近学习','待处理'])+
 '<div class="hintfield muted">'+icon('search')+' 搜索标题、词句或来源</div>'+
 card('最近添加',row('一个有趣的小故事','PDF · 已生成3个学习单元','book',pill('可学习','green'))+row('明天的产品分享','PPT · 有2处需要核对','file',pill('待核对','orange'))+row('十分钟学会做咖啡','网页 · 已保存私有材料','file',pill('待生成'))+row('随手记录的想法','口述 · 00:48 · 私有草稿','mic',pill('草稿','gray')))+
 card('助手收件箱',txt('外部助手送来的内容，先预览再决定学不学。','muted small')+btn('查看2条待确认','m10','secondary'),'compact')+
 note('长材料可以在应用内拆成多个单元，不必重新上传。'),active='材料')

phone('m04','添加学习材料','开始与材料',
 '<h2>我的材料</h2>'+card('最近添加',row('一个有趣的小故事','3个学习单元','book')+row('明天的产品分享','待核对','file')),
 active='材料',cls='sheetphone',extra='<div class="veil"></div><div class="sheet"><div class="handle"></div><h2>添加学习材料</h2>'+txt('把你想学的内容带进来。','muted small')+row('上传文件','文档、图片、音视频','cloud')+row('粘贴内容','文字或网页链接','edit')+row('说一段','口述想法，变成学习材料','mic')+note('默认仅自己可见。录制表达在学习或分享页进入。')+btn('取消','m03','secondary')+'</div>')

phone('m05','处理前确认','导入与生成',
 '<h2>先确认怎样处理</h2>'+txt('明天的产品分享.pptx · 12页','muted small')+
 card('这一步做什么',line('处理范围','提取文字与图片中的文字')+line('内容用途','预览、核对，不生成练习')+line('保存方式','先保存为私有草稿'))+
 card('数据与费用',txt('如需云端识别，相关页面将发送给所选处理服务。','small')+line('处理服务','尚待选择')+line('本次估算','待服务与计价方案确认')+note('服务、数据去向和费用上限确定后才能开始云端处理。'))+
 '<div class="checkrow"><span class="checkbox"></span><span>仅授权本次提取处理，不包含后续英语生成或公开分享。</span></div>'+note('也可以只保存原文件，稍后决定。'),
 actions=btn('选择服务与本次上限','m26')+btn('只保存，不开始处理','m03','secondary'))

phone('m06','说一段素材','导入与生成',
 '<h2>把想到的，先说下来</h2>'+txt('中文、英文都可以。先录音，再决定是否转写。','muted small')+
 card('录音草稿',waveform()+'<div class="center"><b style="font-size:24px">00:48</b><p class="muted small">录音已暂停</p></div><div class="twobtn">'+btn('试听',None,'secondary',ic='play')+btn('继续录制',None,'ghost',ic='mic')+'</div>')+
 card('接下来可以怎样用',txt('讲个故事、记下一个想法，或准备明天要说的话。','small')+note('这是学习素材，不是发音评测录音。'),'compact')+
 note('转写前会单独确认数据处理范围及费用。'),
 actions=btn('确认转写方式','m05')+btn('仅保存录音草稿','m03','secondary'))

phone('m07','提取内容核对','导入与生成',
 '<div class="spread">'+pill('明天的产品分享 · 第3页')+pill('2处疑点','orange')+'</div>'+
 '<h2>这两处，帮忙看一眼</h2>'+card('原件预览','<div class="hintfield"><b>本周项目进展</b><p>计划于周<span class="highlight">五</span>完成第一版。</p><p>还有3个细节需要确认。</p></div>')+
 card('提取文字','<div class="hintfield">计划于周<span class="highlight">王</span>完成第一版。<br>还有3个细节需要确认。</div>'+txt('疑点：“周王”可能是“周五”','orange small')+'<div class="twobtn">'+btn('改为“周五”',None,'ghost')+btn('手动修改',None,'secondary')+'</div>')+
 note('第8页图片未能读取，可补传截图；其余页面已保留。','warning'),
 actions=btn('确认内容，调整单元','m08')+btn('先处理可读部分','m08','secondary'))

phone('m08','调整学习单元','导入与生成',
 '<h2>拆成几段，慢慢学</h2>'+txt('12页材料，建议分成3个学习单元。','muted small')+
 card('学习单元',row('开场与背景','约2分钟 · 第1—2页','file','调整')+row('本周工作进展','约4分钟 · 第3—6页','file','调整')+row('下一步与待确认','约3分钟 · 第7—12页','file','调整'),'compact')+
 '<div><h3>英语表达</h3>'+chips(['保留原意','更适合我说'])+txt('名字、数字与观点保留，改写处可对照核查。','muted tiny')+'</div>'+
 '<div><h3>这次想练</h3>'+chips(['听懂与交流','演讲准备'])+'</div>'+
 note('本次生成含英语、音频和练习；费用估算确认后才执行。'),
 actions=btn('查看生成估算','m26')+btn('保存配置，稍后生成','m03','secondary'))

phone('m09','处理任务与恢复','导入与生成',
 '<div class="spread"><h2>文本和音频已保留</h2><a class="small indigo" href="#m36">反馈问题</a></div>'+txt('明天的产品分享 · 任务详情','muted small')+
 card('当前进度',row('提取与英语表达','已完成，可查看和修改','check',pill('完成','green'))+row('朗读音频','已完成，可先听读','volume',pill('完成','green'))+row('字幕视频','响应超时，正在核查结果','clock',pill('待核查','orange')))+
 card('不用从头再来',txt('视频结果还不确定，先核查再决定是否续做。已完成内容可以继续使用。','small')+btn('核查视频结果',None,'secondary'),'soft')+
 note('结果未知不等于失败，费用也可能尚未结算。')+note('取消请求需等待确认；不保证外部服务立即停止或零费用。'),
 actions=btn('先开始听读','m11')+btn('查看用量与任务状态','m26','secondary'))

phone('m10','助手收件箱','助手与学习',
 '<div class="spread"><h2>内容到了，先看一眼</h2>'+pill('接入示意','gray')+'</div><a class="sectionlink" href="#m35">连接外部助手</a>'+txt('送入不等于自动生成，也不会自动公开。','muted small')+
 card('昨日回顾与今日计划','<div class="tagrow">'+pill('Codex')+pill('定时送入 · 示例')+pill('新版本 v2','orange')+'</div>'+line('接收账号','我的个人空间 · 仅自己')+line('来源时间','昨天 · 保留来源引用')+txt('与已接收的v1同源。先核对回顾事实与计划建议，再决定是否生成。','small')+'<div class="twobtn">'+btn('查看差异',None,'secondary')+btn('预览内容','m07','ghost')+'</div>')+
 card('一个小故事',txt('WorkBuddy · 手动送入 · 相同投递','muted small')+note('重复送入关联原材料，不重复建副本或生成。'),'compact')+
 '<div class="twobtn">'+btn('稍后', 'm03','secondary')+btn('忽略', 'm03','secondary')+'</div>'+note('平台主动读取来源为后续能力，需另行限定来源、时间和范围。'),
 actions=btn('确认内容，查看生成用量','m08'))

# Listening, lookup and professional pronunciation.
def camera_preview(unopened=False,small=False):
 badge='人物占位示意 · 摄像头未开启' if unopened else '真人视频 · 成片示意'
 portrait='<svg viewBox="0 0 320 150" aria-label="人物画面占位示意"><rect x="40" y="16" width="240" height="125" rx="8" fill="#2c3c5c"/><path d="M111 149c0-42 20-62 49-62s49 20 49 62" fill="#a1adc8"/><ellipse cx="160" cy="61" rx="29" ry="33" fill="#d6dcec"/><path d="M130 57c-3-27 13-39 29-39 24 0 36 15 31 40-8-5-14-15-16-21-12 13-30 18-44 20" fill="#7886a5"/><path d="M151 72c6 5 12 5 18 0" fill="none" stroke="#7c88a2" stroke-width="2" stroke-linecap="round"/><path d="M67 31h12M67 31v12M253 31h-12M253 31v12" stroke="#c4cce1" stroke-width="2" fill="none"/></svg>'
 return '<div class="camera-preview '+('small-preview' if small else '')+'"><span class="preview-badge">'+badge+'</span>'+portrait+'<div class="preview-caption">Here’s what I worked on yesterday.</div></div>'

def layered_reader(expanded=False):
 paragraphs=[
 ('Let me walk you through the main idea.','我来给你讲讲主要思路。',False),
 ('There are still a few <a href="#m12" class="selectedword">details</a> to work out.','还有几个细节需要确认。',True),
 ('Here’s what I’m planning to do next.','接下来，我打算这样推进。',False),
 ('First, I’ll check a few things with the team.','首先，我会和团队确认几件事。',False),
 ('Then we can agree on the next steps.','然后，我们就能商定下一步。',False),
 ('I’ll keep you posted on how things go.','有新的进展，我会告诉你。',False)]
 article='<div class="reader-article" aria-label="完整学习正文，可独立滚动"><div class="article-meta"><span>正文 · 可上下滚动</span><span>第6 / 18句 · 已暂停</span></div>'
 for en,zh,current in paragraphs:
  article+='<div class="reading-paragraph '+('read-current' if current else '')+'"><p class="english">'+en+'</p><p class="translation">'+zh+'</p></div>'
 article+='</div>'
 options='<div class="reader-options"><div class="spread">'+pill('第2 / 4节 · 工作进展')+'<span class="small muted">目录</span></div>'+chips(['双语','0.8×','单句循环'])+'</div>'
 destination='m11' if expanded else 'm12'
 dock='<div class="dictionary-dock '+('expanded' if expanded else '')+'"><div class="spread dock-toprow"><span><span class="dock-word">details</span><span class="dock-pron">/ˈdiːteɪlz/</span></span><span class="dock-icon">'+icon('volume')+'<a href="#m19" aria-label="加入词句本">'+icon('plus')+'</a></span></div><div class="spread dock-bottomrow"><span>细节；具体事项</span><a href="#'+destination+'" class="indigo">点词查词 · '+('收起 ⌄' if expanded else '展开 ⌃')+'</a></div>'
 if expanded:
  dock+='<div class="dock-example"><div class="spread"><b>Let’s go over the details.</b>'+icon('volume')+'</div><small>我们来过一下具体细节。 · 学习例句</small></div><div class="dock-actions">'+btn('加入词句本','m19','secondary smallbtn','plus')+btn('收起词卡','m11','ghost smallbtn')+'</div>'
 dock+='</div>'
 controls='<div class="reader-controls">'+bar(37)+'<div class="spread tiny muted"><span>01:36</span><span>04:20</span></div><div class="controls"><span>ı◀</span><span class="round">'+icon('play')+'</span><span>▶ı</span></div><div class="twobtn">'+btn('这一句没听懂',None,'secondary')+btn('跟读 / 复述','m13','primary')+'</div></div>'
 return options+article+controls+dock

phone('m11','按钮下方 · 两行词卡','听读与纠音',layered_reader(),header='昨天的工作总结')
phone('m12','按钮保留 · 词卡展开','听读与纠音',layered_reader(True),header='昨天的工作总结')

phone('m13','跟读与录音质量','听读与纠音',
 pill('跟读 · 显示全文')+'<h2>先听一句，再试一次</h2>'+card('这次读这一句','<p class="english">Let me walk you through the plan.</p><p class="translation">我来给你逐步讲讲这个计划。</p>'+btn('听示范',None,'secondary','volume'))+
 '<div class="recordarea">'+waveform()+'<span class="small muted">录音 00:08 · 质量检查未通过</span></div>'+
 card('这次背景声有些大',txt('找个稍安静的地方，把手机靠近一点再录。先不生成发音分。','small')+note('原始录音可以保留并回听。','warning'),'warning compact'),
 actions=btn('重新录一句',None,'primary','mic')+btn('回听本次录音',None,'secondary','play'))

phone('m14','专业发音反馈','听读与纠音',
 '<div class="spread">'+pill('有稿朗读')+pill('演示结果','gray')+'</div><h2>这次，先改一个地方</h2>'+
 card('发音评测参考分','<div class="spread"><span class="bigmetric indigo">82 <small>/ 100</small></span><span class="muted small">不是82%准确率</span></div>'+txt('同一服务与版本 · 本句朗读样本','muted tiny'),'compact')+
 card('through /θruː/',txt('示例重点：开头的 /θ/','indigo small')+txt('舌尖轻放在上下齿之间，轻轻送气，声带不振动。','small')+btn('听慢速示范',None,'secondary','volume'),'soft')+
 '<div><h3>回听同一句</h3>'+row('这一次','原始人声 · 有稿朗读','volume','▶')+row('上一次','同句同条件 · 示例','volume','▶')+'</div>'+note('录音太短或服务不可用时，显示未评测，不补造分数。'),
 actions=btn('带着这个提示，再说一次','m13','primary','mic'))

# Review and conversation.
phone('m15','词句填空选择','复习与交流',
 '<div class="taskhead"><b>本轮：选个表达</b><span>随时可结束</span></div>'+pill('来自：我的工作总结')+'<h2>选个词，把话补完整</h2>'+
 card('','<p class="english large">Let me ____ you through the plan.</p><p class="translation">我来给你逐步讲讲这个计划。</p>','soft')+
 '<div>'+''.join(f'<div class="choice {"on" if n==0 else ""}"><span class="radio"></span><span class="grow"><b>{chr(65+n)}.</b> {w}</span><span class="listen">{icon("volume")}</span></div>' for n,w in enumerate(['walk','make','tell']))+'</div>'+
 note('点喇叭只试听；确认选择后再看解释。')+btn('给点提示',None,'secondary'),header='今日复习',
 actions=btn('确认选择','m17')+btn('先练到这里','m02','ghost'))

phone('m16','听问题选回应','复习与交流',
 '<div class="taskhead"><b>本轮：听问接话</b><span>随时可结束</span></div>'+pill('场景：同事问项目进展')+'<h2>听问题，选能接上的话</h2>'+
 '<div class="questionaudio"><span class="round">'+icon('volume')+'</span><h3>听问题</h3><span class="muted tiny">先听，再按需展开文字</span></div>'+
 '<div class="twobtn">'+btn('慢一点',None,'secondary smallbtn')+btn('显示问题文字',None,'secondary smallbtn')+'</div>'+
 '<div>'+''.join(f'<div class="choice"><span class="radio"></span><span class="grow">{a}</span><span class="listen">{icon("volume")}</span></div>' for a in ['It’s going well. We’re almost done.','We’ve hit a snag. We need more time.','I’ll walk you through the plan.'])+'</div>'+
 note('可能有不止一种合理回应；结合问题和真实情况选择。'),header='今日复习',
 actions=btn('确认回应','m17','disabled')+btn('稍后再练','m02','ghost'))

phone('m17','答后解释与回原句','复习与交流',
 '<div class="spread">'+pill('本轮反馈')+pill('含文字提示','orange')+'</div><h2>这两句，都能接上</h2>'+
 card('对方问项目进展',txt('How’s the project coming along?','bold')+txt('项目进展怎么样？','muted small'))+
 card('进展顺利时',txt('It’s going well. We’re almost done.','bold')+txt('进展不错，我们快完成了。','muted small'),'soft compact')+
 card('遇到困难时',txt('We’ve hit a snag. We need more time.','bold')+txt('遇到一点问题，我们需要更多时间。','muted small'),'compact')+
 txt('“I’ll walk you through the plan.” 是介绍计划，通常还需要补一句当前进展。','small')+
 note('本次使用了问题文字，不计为独立听力通过。答对一次不代表长期记住。'),header='今日复习',
 actions='<div class="twobtn">'+btn('回原句听听','m11','secondary')+btn('自己说一句','m18')+'</div>'+btn('稍后重练，今天先到这里','m02','ghost'))

phone('m18','自己回答与短对话','复习与交流',
 '<div class="taskhead"><b>本轮：自己说一句</b><span>随时可结束</span></div>'+pill('场景：同事问项目进展')+'<h2>换成你的情况，说一句</h2>'+
 card('再听问题',txt('How’s the project coming along?','bold')+'<div class="spread">'+btn('再听',None,'ghost smallbtn','volume')+'<span class="sectionlink">查看中文</span></div>')+
 chips(['自己回答','关键词','听个示范'])+txt('可以说说进展，再补充一个细节。','muted small')+
 '<div class="recordarea"><span class="round large">'+icon('mic')+'</span><b>开始回答</b><span class="small muted">不方便开口？稍后再练</span></div>'+
 note('下一轮会根据你的回答追问；不同于示范但合理的表达也能被接受。')+note('本页显示问题文字；帮助条件会随练习保存。'),header='今日复习',
 actions=btn('录完后查看反馈','m14')+btn('录成视频或音频作品','m21','secondary'))

phone('m19','我的词句本','复习与交流',
 '<h2>放回自己的句子里记</h2>'+chips(['待复习','最近收藏','全部'])+
 card('今天先练一小组',txt('3个词句 · 约3分钟','muted small')+btn('听懂，再试着接话','m15'),'soft')+
 card('details',txt('There are still a few details to work out.','bold small')+txt('还有几个细节需要确认。','translation')+'<div class="tagrow">'+pill('认识：待复测')+pill('听辨：已练')+pill('运用：待练','gray')+'</div>'+line('原句来源','工作总结 · 第6句'),'compact')+
 card('walk someone through',txt('带某人逐步了解','small')+txt('来自：明天的产品分享','muted tiny'),'compact')+
 '<div class="spread"><b class="small">想练拼写？</b><span class="sectionlink">进入可选专项</span></div>'+note('到期内容会分成小组安排，今天不用清空所有词。'),header='我的词句本',
 actions=btn('返回学习','m02','secondary'))

# Sharing.
phone('m20','分享与我的作品','作品与分享',
 chips(['我的作品','发现 · 分期开放'])+
 card('把学会的，说给自己听',txt('先保存为私有草稿，再决定是否分享。','muted small')+btn('录音 / 录视频','m21','primary','camera'),'soft')+
 '<h3>最近作品</h3>'+camera_preview(small=True)+'<div class="spread small"><b>昨天的工作总结 · 视频复述</b><span class="muted">00:42</span></div>'+
 '<div class="spread">'+pill('私有草稿','gray')+'<a class="sectionlink" href="#m22">继续编辑</a></div>'+btn('预览并分享','m23','secondary')+
 card('第一次练习',txt('00:28 · 仅自己可见','muted small')+txt('随时回听，不必公开打卡。','small'),'compact')+
 note('原文、分数和私人点评不会自动公开。'),header='分享',active='分享')

phone('m21','录音或真人视频','作品与分享',
 chips(['录音','真人视频'],1)+camera_preview(unopened=True)+
 '<div class="spread small"><span>昨天的工作总结 · 第2节</span><a class="sectionlink" href="#m03">换内容</a></div>'+chips(['全文提示','关键词','无提示'],1)+
 card('关键词提示',txt('progress · details · next steps','small indigo'),'compact')+
 '<div class="recordarea"><span class="round large">'+icon('camera')+'</span><b>开始录视频</b><span class="sectionlink">开启摄像头预览 · 切换前后镜头</span></div>'+note('开始前确认相机与麦克风权限；录好先存私有草稿。'),
 actions=btn('录完后校对视频字幕','m22')+btn('先存草稿','m20','secondary'))

phone('m22','字幕校对与片段','作品与分享',
 camera_preview(small=True)+'<div class="spread small"><span>▶ 播放原视频</span><span class="muted">00:42 · 原声</span></div>'+
 '<h3>选择要分享的片段</h3><div class="hintfield"><div class="spread small"><span>起点 00:04</span><span>终点 00:38</span></div>'+bar(80)+'</div>'+
 card('英文字幕','<div class="hintfield">Here’s what I worked on yesterday.</div>','compact')+
 card('中文字幕','<div class="hintfield">我来说说昨天做了什么。</div>','compact')+
 note('字幕可以修改；修改文字不改变原始人声或发音评测结果。'),
 actions=btn('预览作品与分享范围','m23')+btn('保存草稿','m20','secondary'))

phone('m23','分享预览与范围','作品与分享',
 '<div class="thumb" style="padding:10px 15px"><div class="spread"><span>▶ 昨天的工作总结 · 00:34</span><span>双语字幕</span></div></div>'+
 '<h3>站内谁可以看</h3>'+chips(['仅自己','指定人','持链接','公开·后续'])+
 '<div class="card compact">'+line('包含原文件','不包含')+line('包含成绩与点评','不包含')+note('只分享确认过的作品版本。')+'</div>'+
 '<h3>导出或前往平台发布</h3><div class="card compact">'+line('抖音','按获批能力前往发布')+line('小红书','前往App继续确认')+line('微信视频号','导出视频后按指引发布')+'</div>'+
 note('三个平台能力不同，不会自动全部发布。站内分享需另行选择范围。'),
 actions=btn('导出作品视频','m24')+btn('返回修改','m22','secondary'))

phone('m24','分享状态与撤回','作品与分享',
 '<h2>每个渠道，分别看状态</h2>'+txt('昨天的工作总结 · 发布版本1','muted small')+
 card('站内分享',line('范围','指定的人')+line('状态','已分享 · 示例')+btn('查看访问范围',None,'secondary'),'compact')+
 card('外部渠道',line('抖音','已打开平台 · 未确认发布')+line('小红书','未发送')+line('微信视频号','已导出 · 发布结果未知')+note('打开目标App或导出成功，不代表作品已公开。'),'compact')+
 card('撤回站内分享后',txt('停止新的站内访问。他人自己的学习记录保留；外部平台和已导出副本需另行管理。','small'),'soft compact')+
 note('私有草稿的修改不会自动覆盖已发布作品。'),
 actions=btn('撤回站内分享',None,'danger')+btn('返回我的作品','m20','secondary'))

# Progress, cost and assets.
phone('m25','我的进步看板','我的与管理',
 '<div class="spread"><h2>每一点，都留下痕迹</h2><span class="tiny muted">示例　<a class="sectionlink" href="#m27">管理</a></span></div>'+chips(['本周','近30天'])+
 '<div class="metrics"><div><b class="bigmetric">86</b><small>有效练习分钟</small></div><div><b class="bigmetric">18</b><small>主动开口分钟</small></div></div>'+
 card('这一周的练习','<div class="chartbars">'+''.join(f'<i style="height:{round(v/1.56)}px"></i>' for v in [24,55,18,44,66,31,73])+'</div><div class="chartlabels">'+''.join(f'<span>{x}</span>' for x in '一二三四五六日')+'</div>','compact')+
 card('发音，正在变得清楚','<div class="spread"><b style="font-size:24px" class="indigo">76 → 82</b><span class="small muted">4次朗读样本</span></div><p class="tiny muted">同一评测方式 · 相似任务 · 示例</p>','compact')+
 card('听懂与表达',line('延迟复习独立答对','6 / 10项')+line('本周使用文字提示','4次')+line('拼写专项','尚未练习'),'compact')+
 '<div class="spread small"><a href="#m19" class="sectionlink">词句本</a><a href="#m26" class="sectionlink">用量预算</a><a href="#m27" class="sectionlink">隐私资产</a><a href="#m36" class="sectionlink">帮助反馈</a></div>',header='我的进步',active='我的')

phone('m26','用量与预算','我的与管理',
 '<h2>每一步，先知道用量</h2>'+txt('估算、预留和实耗分开查看。','muted small')+
 card('本次处理估算',line('材料规模','12页 · 约1800字')+line('处理范围','按当前批准的计划核算')+line('费用估算','服务方案确认后显示')+line('本次上限','尚未设置')+note('示例；教练规划也计入用量，暂无报价或扣费。'),'soft')+
 card('处理中用量',line('已预留','待任务与计价确认')+line('已结算实耗','暂无实际账单')+line('结果未知任务','1项 · 等待核查'),'compact')+
 card('超出上限时',txt('暂停新的付费步骤，提示你调整范围或上限，不静默继续。','small'),'compact')+
 note('外部助手自身费用与平台处理费用分别核算；失败不等于外部服务免费。'),
 actions=btn('设置本次上限',None,'secondary')+btn('费用未确认，暂不生成','m03','ghost'))

phone('m27','隐私与个人资产','我的与管理',
 '<h2>内容和授权，由你管理</h2><div class="spread small indigo"><a href="#m26">用量与预算</a><a href="#m34">学习教练权限 ›</a></div>'+
 card('来源授权',line('外部助手送入','仅指定账号 · 示例连接')+line('平台主动读取','未接入 · 后续验证')+txt('来源：由我指定　时间：仅授权窗口<br>范围：指定内容　定时：未启用','muted tiny')+note('撤销来源授权不会自动删除已保存材料。'),'compact')+
 card('导出我的内容',txt('选择材料、词句、练习记录或作品；导出结果会列出未完成项。','small')+btn('选择导出范围',None,'secondary','download'),'compact')+
 card('删除内容',txt('先选择范围，再核对影响。未选择任何删除项。','small')+btn('查看删除范围',None,'secondary'),'compact')+
 note('撤权、取消任务、撤回分享和删除历史是不同操作。')+note('已导出或在外部平台发布的副本，不随本站删除自动收回。'),header='隐私与资产',
 actions=btn('返回我的','m25','secondary'))

phone('m28','粘贴文字或网页','导入与生成',
 '<h2>把想学的内容贴过来</h2>'+chips(['文字','网页链接'])+
 card('文字内容','<div class="hintfield" style="min-height:150px">昨天听到一个小故事：<br><br>一个人每天只练十分钟，慢慢发现自己敢开口了……</div>','compact')+
 '<div class="spread small muted"><span>可修改标题与内容</span><span>42字 · 示例</span></div>'+
 card('如果添加网页',txt('粘贴网页地址，提取前先确认处理范围。','small')+note('需要登录或无法读取时，可以改贴正文或上传截图。'),'compact')+
 note('先保存私有草稿；识别、改写与生成各自确认，不自动开始付费处理。'),
 actions=btn('保存并核对内容','m07')+btn('先存草稿','m03','secondary'))

phone('m29','登录与跨端进入','开始与材料',
 '<div style="padding:23px 0 5px">'+icon('book')+'</div><h1>换个设备，<br>继续自己的内容。</h1>'+txt('同一账号保留材料、词句与学习记录。','muted small')+
 card('选择进入方式',row('使用已有账号','登录后确认个人空间归属','user','›')+row('创建个人账号','材料默认私有，不自动公开','lock','›'))+
 card('这个账号里有什么',txt('自己的材料与作品草稿、练习记录，以及允许同步的播放位置。','small')+note('公用设备退出后不要保留登录。'),'compact')+
 '<div class="checkrow"><span class="checkbox"></span><span>我已阅读服务条款与隐私说明。<br><span class="muted tiny">未默认勾选；本图不进行注册或登录。</span></span></div>',header='拾语',
 actions=btn('选择账号进入',None,'secondary')+btn('返回了解产品','m01','ghost'))

phone('m30','跨端续学与新版本','助手与学习',
 '<h2>要从哪一版继续？</h2>'+txt('明天的产品分享 · 设备切换','muted small')+
 card('上次学到这里',line('设备','iPhone · 刚才')+line('学习版本','版本1 · 第2节第5句')+line('当前同步','正在同步，尚未确认最新')+btn('核对同步状态',None,'secondary'),'compact')+
 card('材料有了新版本',txt('版本2修改了第3页，并重新拆分单元。旧版练习与词句保留。','small')+note('新旧句子不一定对应，不直接搬用旧百分比。'),'soft')+
 note('可以继续旧版，或查看差异后切换新版。不静默覆盖另一台设备的进度。'),
 actions=btn('继续版本1','m11')+btn('查看差异后切换版本2','m07','secondary'))

# Desktop designs.
# Controlled coach: five added static review states.
phone('m31','学习教练','学习教练与Agent',
 '<h2>现在，想怎么练？</h2>'+txt('你选内容，我来帮你安排下一步。','muted small')+
 card('这次只用这份材料',row('昨天的工作总结','已选1份 · 学习版本1','file','')+'<a class="sectionlink" href="#m03">换一份材料</a>','compact')+
 '<div><h3>现在方便做什么</h3>'+chips(['听和选择','方便开口'])+'</div>'+
 '<div><h3>这一轮想花多久</h3>'+chips(['约3分钟','约10分钟','自己调整'])+'</div>'+
 card('这次的目标',txt('先听懂，再试着接上一句话。','small')+note('你可以改计划、跳过或随时结束。'),'soft compact')+
 '<a class="sectionlink" href="#m34">本次可用材料与权限</a>'+note('规划模型也计入用量，先确认范围和上限；不会替你公开分享。'),
 actions=btn('确认教练权限与用量','m34')+btn('我自己选练习','m15','secondary'))

phone('m32','可修改的练习计划','学习教练与Agent',
 '<div class="spread">'+pill('约3分钟 · 计划示例')+'<a class="small indigo" href="#m33">安排状态</a></div><h2>先练少一点，记得更牢</h2>'+
 card('这一轮怎么练',row('选个表达','1道词句选择 · 可试听','book','调整')+row('听问接话','1道场景题 · 可慢放','volume','调整')+row('自己说一句','今天不便开口，稍后可练','mic','暂不安排'),'compact')+
 card('为什么这样安排',txt('上次这一段使用了文字提示，先用相同主题再练一次。','small')+txt('依据：昨天的工作总结 · 上次练习记录（示例）','muted tiny'),'soft compact')+
 '<div class="twobtn">'+btn('换一组内容','m31','secondary')+btn('改时间或方式','m31','secondary')+'</div>'+
 note('优先使用已有内容；需要新增生成时，先确认处理范围与用量。')+note('你的修改优先，不因跳过或结束扣除进度。'),
 actions=btn('确认权限与用量后开始','m34')+btn('先体验示例练习','m15','secondary'))

phone('m33','教练状态与停止','学习教练与Agent',
 '<h2>每一步，你都看得到</h2>'+txt('本次安排 · 只使用所选材料','muted small')+
 card('本次操作记录',row('读取已选材料','昨天的工作总结 · 版本1','check',pill('完成','green'))+row('参考本次允许的练习记录','文字提示使用 · 不推断总体水平','check',pill('完成','green'))+row('保存可修改的计划草稿','等待你开始，不自动打开麦克风','clock',pill('待开始')),'compact')+
 card('停止时会怎样',txt('停止后不再开始新的步骤；已完成内容保留。','small')+note('如果有正在执行的外部处理，会单独显示取消或结果待核查。'),'soft compact')+
 '<a class="sectionlink" href="#m09">有结果待核查？查看任务</a>'+note('这里展示动作和状态，不展示模型内部推理或敏感提示内容。'),
 actions=btn('返回本次计划','m32')+btn('停止后续安排','m31','secondary','stop'))

phone('m34','教练权限与记忆','学习教练与Agent',
 '<h2>只在你允许的范围帮忙</h2>'+
 card('本次可用范围',line('材料','所选1份 · 不读取整个材料库')+line('练习记录','仅本次允许的已确认记录')+line('可以做','建议练习、保存计划草稿')+line('规划用量上限','尚未设置，不启动模型'),'compact')+
 card('长期记忆',line('个人偏好与个人事实','未开启')+txt('本次目标可临时使用；长期保存需你选择，可查看、修正或删除。','small')+'<a class="sectionlink" href="#m27">管理学习记录与资产</a>','soft compact')+
 card('这些仍由你决定',txt('新增付费处理、读取新来源、公开分享和删除内容，不由学习教练自行执行。','small'),'compact')+
 note('<a class="indigo" href="#m27">管理或收回本次权限</a>；已开始的任务另行核查，历史数据不会自动删除。'),
 actions=btn('设置教练用量上限','m26')+btn('查看计划示例','m32','secondary'))

phone('m35','连接外部助手','学习教练与Agent',
 '<div class="spread"><h2>整理好，直接送进来</h2>'+pill('尚未接入','gray')+'</div>'+txt('用于Codex、WorkBuddy等外部助手。','muted small')+
 card('连接只允许什么',line('接收空间','我的个人空间')+line('允许动作','送入材料、查询本人投递回执')+line('内容状态','私有待确认，不自动生成'),'compact')+
 card('送入之后',row('核对来源与版本','重复投递不重复建副本','file','')+row('我再决定是否学习','处理范围与用量单独确认','check',''),'soft compact')+
 note('连接不会开放其他材料、其他应用或学习教练的执行权限。')+note('正式接入需独立鉴权；密钥不会显示在原型或写进材料。')+
 '<a class="sectionlink" href="#m27">平台主动读取来源：后续能力</a>',
 actions=btn('查看连接说明',None,'secondary')+btn('查看助手收件箱','m10'))

phone('m36','帮助与反馈','帮助与反馈',
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

desktop('d01','材料工作台',
 '<div class="deskintro"><div><h1>自己的内容，才是学习的起点。</h1><p>原件、提取内容和学习单元放在一起核对。</p></div>'+pill('默认私有')+'</div>'+
 '<div class="deskgrid two"><div>'+card('最近材料',row('明天的产品分享.pptx','12页 · 2处疑点 · 正在核对','file',pill('待核对','orange'))+row('一个有趣的小故事.pdf','3个单元 · 最近在手机听到第2节','book',pill('可学习','green'))+row('十分钟学会做咖啡','网页 · 私有待生成','file',pill('待生成')))+
 card('原件与提取内容','<div class="deskgrid equal"><div class="docpreview"><h3>原件 · 第3页</h3><p>本周项目进展</p><p>计划于周<span class="highlight">五</span>完成第一版。</p><div class="docline"></div><div class="docline" style="width:70%"></div></div><div><div class="hintfield">计划于周<span class="highlight">王</span>完成第一版。</div><p class="orange small">疑点：“周王”可能是“周五”</p>'+btn('修改这一处',None,'secondary')+'<p class="muted small">第8页缺失图片，可补传后单独处理。</p></div></div>')+'</div><div>'+card('助手收件箱',row('昨天的工作总结','Codex · 同源v2 · 接入示意','file',pill('待确认'))+note('重复送入关联原材料；接收不等于自动生成。')+btn('预览来源与版本','m10','secondary'))+
 card('学习单元与表达',line('单元1','开场与背景 · 约2分钟')+line('单元2','工作进展 · 约4分钟')+line('单元3','下一步 · 约3分钟')+chips(['保留原意','更适合我说'])+txt('数字、姓名、观点和改写位置可核对。','muted small')+btn('确认内容，查看生成估算','m08'))+
 note('手机与电脑都可以添加材料；切换设备继续同一版本。')+'</div></div>')

desktop('d02','学习工作台',
 '<div class="deskintro"><div><h1>昨天的工作总结</h1><p>第2 / 4节 · 工作进展 · 学习版本1</p></div>'+btn('录下这次表达','m21','secondary','camera')+'</div>'+
 '<div class="desknotice"><span>材料有新版本。旧版练习与定位会保留，切换前可先看差异。</span><span>继续旧版　　查看新版</span></div>'+
 '<div class="deskgrid three"><div>'+card('学习单元',row('开场与背景','已听读','book','')+row('工作进展','正在学习 · 第5句','book','')+row('下一步计划','待学习','book','')+row('总结与复述','待练习','mic',''),'compact')+note('本周手机上次位置：同版第5句。')+'</div>'+
 '<div class="deskbig">'+chips(['双语','0.8×','单句循环'])+'<div class="sentence"><p class="english muted">Yesterday, I worked on a few key updates.</p><p class="translation">昨天，我推进了几项重点工作。</p></div><div class="sentence current"><p class="english">Let me walk you through the main idea.</p><p class="translation">我来给你讲讲主要思路。</p></div><div class="sentence"><p class="english">There are still a few <span class="selectedword">details</span> to work out.</p><p class="translation">还有几个细节需要确认。</p></div>'+player()+'<div class="twobtn">'+btn('这一句没听懂',None,'secondary')+btn('跟读 / 自己回答','m13')+'</div></div>'+
 '<div>'+card('点词查看','<p class="wordtitle">details</p><div class="spread"><span class="small muted">美 /ˈdiːteɪlz/</span>'+icon('volume')+'</div><p>细节；具体事项</p><p class="muted small">名词复数，原形 detail</p><div class="divider"></div><p class="small bold">Let’s go over the details.</p><p class="translation">我们来过一下具体细节。</p><p class="muted tiny">学习例句 · 原句来源另行保留</p>'+btn('加入词句本','m19','secondary','plus'))+
 card('学习教练',txt('按当前材料安排小回合，计划可修改。','small')+btn('让教练帮我安排','m31'))+'</div></div>',active='学习')

desktop('d03','我的进步与管理',
 '<div class="deskintro"><div><h1>每一点，都留下痕迹。</h1><p>分开看练习、听懂和表达，不用一个总分代替所有变化。</p></div><div>'+pill('所有数据为示例','gray')+'　'+pill('本周')+'</div></div>'+
 '<div class="deskmetric"><div><b class="bigmetric">86<span class="small"> 分钟</span></b><small>有效练习</small></div><div><b class="bigmetric">18<span class="small"> 分钟</span></b><small>主动开口</small></div><div><b class="bigmetric">6 / 10</b><small>延迟复习独立答对</small></div><div><b class="bigmetric">4<span class="small"> 次</span></b><small>文字提示使用</small></div></div>'+
 '<div class="deskgrid equal"><div>'+card('这一周的练习','<div class="chartbars">'+''.join(f'<i style="height:{v}px"></i>' for v in [45,100,25,75,124,60,139])+'</div><div class="chartlabels">'+''.join(f'<span>{x}</span>' for x in ['周一','周二','周三','周四','周五','周六','周日'])+'</div>'+txt('播放时长另行记录，不直接当作理解或掌握。','muted small'))+
 card('词句在真实场景里使用','<table class="desktable"><tr><th>维度</th><th>当前记录</th><th>条件</th></tr><tr><td>词义回忆</td><td>19项已练</td><td>延迟复测继续安排</td></tr><tr><td>听辨</td><td>6/10独立答对</td><td>无文字/中文帮助</td></tr><tr><td>表达运用</td><td>已尝试4轮</td><td>关键词提示单列</td></tr><tr><td>拼写专项</td><td>未练习</td><td>可选，不计为退步</td></tr></table>')+'</div><div>'+card('发音，正在变得清楚','<div class="spread"><b style="font-size:34px" class="indigo">76 → 82</b><span class="muted small">4次朗读样本 · 示例</span></div><svg class="trend" viewBox="0 0 450 70"><path d="M5 60 L150 44 L300 29 L445 5" fill="none" stroke="#7373df" stroke-width="3"/></svg><p class="muted small">同一服务/版本、相似任务才比较。样本不足时不连成趋势。</p>'+row('回听前后的自己','同篇、同提示条件','volume','▶'))+
 card('管理我的内容',row('用量与预算','估算、预留、实耗与未知','chart','查看')+row('隐私与个人资产','来源授权、导出与删除','lock','管理')+row('四端续学','Android / iPhone / Windows / Mac','cloud','查看'))+'</div></div>',active='我的')

desktop('d04','反馈中心 · 管理端',
 '<div class="deskintro"><div><h1>用户遇到的事，集中处理</h1><p>先核查问题，再关联改进与实际发布；不让反馈只停在收件箱。</p></div><div>'+pill('仅管理角色 · 示例','gray')+'　'+pill('应用内提醒')+'</div></div>'+
 '<div class="feedback-inbox">'+icon('bell')+'<b>6条未读反馈</b><span class="grow">提醒已进入站内收件箱；未读与待处理分开查看。</span><span>查看未读</span></div>'+
 '<div class="feedback-metrics"><div><span>待处理</span><strong>6</strong></div><div><span>处理中</span><strong>3</strong></div><div><span>待验证修复</span><strong>2</strong></div><div><span>本周新增 · 示例</span><strong>11</strong></div></div>'+
 '<div class="feedback-columns"><div>'+card('反馈列表',chips(['全部','投诉优先核查','功能建议','待验证'])+'<table class="feedback-table"><tr><th>编号/类型</th><th>反馈摘要</th><th>状态</th><th>来源</th></tr><tr class="current"><td>FB-0001<br><span class="muted">使用问题</span></td><td>播放到一半时偶尔暂停</td><td>待处理</td><td>Android<br>v0.13示例</td></tr><tr><td>FB-0002<br><span class="orange">投诉申诉</span></td><td>希望复核一次评测结果</td><td>优先核查</td><td>iPhone</td></tr><tr><td>FB-0003<br><span class="muted">功能建议</span></td><td>希望能循环选中的几句话</td><td>待评估</td><td>Windows</td></tr><tr><td>FB-0004<br><span class="muted">内容纠错</span></td><td>这一句的释义可能不合语境</td><td>处理中</td><td>macOS</td></tr></table>'+note('同类问题可以聚合，但每位用户的原始反馈和进度保留。'))+
 card('从反馈进入迭代',line('问题归属','先确认，再分配负责人')+line('迭代关联','已采纳 / 待排期 / 已发布分开')+line('完成条件','版本、复测和用户回复可追溯')+note('AI可以建议分类和摘要，不能擅自关闭投诉或承诺修复日期。'),'compact')+'</div><div>'+card('FB-0001 · 私有详情',txt('播放到一半时偶尔暂停，点重播后能继续。','small')+line('可见范围','提交人和获授权处理者')+line('页面/版本','用户选择附带后才可查看')+line('附件','无附件 · 不自动抓取原文')+'<div class="twobtn">'+btn('领取并标记处理中',None,'secondary')+btn('关联改进事项',None,'ghost')+'</div>')+
 card('给用户回复','<div class="hintfield">已收到，我们会先核对播放状态。有进展会在反馈详情更新。</div><p class="tiny muted">回复草稿 · 发送前人工确认</p>'+btn('确认后站内回复',None,'primary'))+
 card('提醒与处理纪律',line('提醒渠道','首版仅应用内')+line('紧急投诉','优先人工核查')+note('应用关闭时不承诺系统推送；提醒失败不丢反馈。')+note('涉及收费/隐私的处理不自动退款、删材料或修改账本。'),'compact')+'</div></div>',active='我的')

PAGES.sort(key=lambda page:(0 if page['id'].startswith('m') else 1,int(page['id'][1:])))
groups=[]
for p in PAGES:
 if p['group'] not in groups: groups.append(p['group'])
parts=[]
for n,g in enumerate(groups):
 parts.append(f'<h2 id="group-{n}" class="grouphead">{g}</h2><div class="grid">')
 for p in [x for x in PAGES if x['group']==g]:
  parts.append(f'<figure class="frame"><figcaption class="caption"><span>{p["id"].upper()}</span><b>{p["title"]}</b><span>{p["width"]}×{p["height"]}</span></figcaption>{p["html"]}</figure>')
 parts.append('</div>')
canvas_summary=f'{sum(p["id"].startswith("m") for p in PAGES)}张手机画布 + {sum(p["id"].startswith("d") for p in PAGES)}张桌面画布。'
doc='<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>拾语 · 完整静态原型 v0.13</title><style>'+CSS+'</style></head><body><header class="galleryhead"><h1>拾语 · 完整静态原型 v0.13</h1><p>'+canvas_summary+'仅用于产品评审：所有内容、评分和状态均为设计示例，尚未接通任何服务。<br>源文件可编辑；按钮与声音为示意，锚点只用于页面走查，不执行真实操作。</p><nav class="toc">'+''.join(f'<a href="#group-{i}">{g}</a>' for i,g in enumerate(groups))+'</nav></header><main class="gallery">'+''.join(parts)+'</main></body></html>'
(ROOT/'index.html').write_text(doc,encoding='utf-8')
(ROOT/'manifest.json').write_text(json.dumps([dict((k,v) for k,v in p.items() if k!='html') for p in PAGES],ensure_ascii=False,indent=2),encoding='utf-8')
print(f'Authored {len(PAGES)} static screens; no browser or product code executed.')
