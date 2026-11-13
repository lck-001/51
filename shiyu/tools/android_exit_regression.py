"""Bounded playback/background/Back regression on an existing synthetic emulator lab."""
import sys,time,json,re,argparse
from android_probe_regression import Probe,PACKAGE
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adb',required=True)
parser.add_argument('--port',required=True,type=int)
parser.add_argument('--serial',required=True)
parser.add_argument('--cycles',type=int,default=3,choices=range(1,6))
args=parser.parse_args()
p=Probe(args.adb,args.port,args.serial);p.preflight()
logs=[]
for cycle in range(args.cycles):
 p.launch()
 p.choose('playback-video-12s.mp4','ShiyuLab_M14')
 p.top();p.wait(lambda t:t.contains('导入完成：playback-video-12s.mp4'),'import_outcome_missing');p.ready()
 # Import inserts the new row first. SAF list-delta checks run separately.
 for _ in range(5):
  tree=p.tree();rows=tree.rows()
  if rows:break
  p.scroll(tree)
 if not rows:raise RuntimeError('Imported video row not visible')
 row=next(iter(rows))
 if '.mp4' not in row:raise RuntimeError('Expected the newly imported synthetic MP4')
 p.click((row,),scroll=True)
 time.sleep(1)
 pid=p.adb('shell','pidof',PACKAGE).strip()
 p.adb('shell','input','keyevent','KEYCODE_HOME');time.sleep(.5)
 p.launch()
 p.adb('shell','input','keyevent','KEYCODE_BACK')
 time.sleep(3)
 tree=p.tree()
 if tree.package_present(PACKAGE):raise RuntimeError('Exit did not return to launcher')
 app_log=p.adb('logcat','-d','--pid='+pid,'-t','300')
 crashes=p.adb('logcat','-d','-b','crash','-t','250')
 native_crash=bool(re.search(r'Fatal signal.*?pid '+re.escape(pid)+r'\b',app_log)) or bool(re.search(r'pid: '+re.escape(pid)+r',.*mpv',crashes))
 errors=[line for line in app_log.splitlines() if 'Unhandled Exception' in line or 'cleanup did not complete' in line]
 logs.append({'cycle':cycle+1,'backgroundReturned':True,'normalExit':True,'nativeCrash':native_crash,'cleanupErrors':bool(errors)})
 print(json.dumps(logs[-1]),flush=True)
 if native_crash or errors:raise RuntimeError('Native or cleanup failure')
print(json.dumps({"scope":"emulator_playback_background_back_only","cycles":len(logs),"passed":all(not x["nativeCrash"] and not x["cleanupErrors"] for x in logs),"physical_device_verified":False}),flush=True)
