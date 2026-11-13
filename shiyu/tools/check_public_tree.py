"""Audit staged project blobs without printing secret values; optionally refresh manifest."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

args = argparse.ArgumentParser()
args.add_argument('--write-manifest', action='store_true')
options = args.parse_args()
project = Path(__file__).resolve().parents[1]
repo = project.parent
prefix = project.name + '/'
paths = subprocess.check_output(['git','ls-files','--cached','-z','--',project.name], cwd=repo).split(b'\0')
names = [p.decode('utf-8') for p in paths if p]
if not names:
    raise SystemExit('No staged project source to audit')
process = subprocess.run(['git','cat-file','--batch'], cwd=repo,
                         input=b''.join((':'+n+'\n').encode() for n in names), stdout=subprocess.PIPE, check=True)
raw = process.stdout
offset = 0
issues = []
files = []
patterns = {
    'credential': re.compile(r'modao_[A-Za-z0-9]{20,}|\bsk-(?:proj-)?[A-Za-z0-9_-]{25,}|\bgh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bAKIA[A-Z0-9]{16}\b|\bLTAI[A-Za-z0-9]{16,}'),
    'personal_home_path': re.compile(r'C:[/\\]+Users[/\\]+(?!Public\b|Default\b|example\b|YOUR_|<)[^/\\\s"\x27]+[/\\]',re.I),
    'private_document': re.compile(r'alidocs\.dingtalk\.com/i/nodes/|ding[a-f0-9]{24,}',re.I),
    'file_base': re.compile(r'<base\s+href=["\x27]file:',re.I),
}
blocked = {'.toolchains','.dart_tool','.gradle','.cxx','ephemeral','results','archive','research','__pycache__'}
for name in names:
    end = raw.index(b'\n', offset)
    header = raw[offset:end].split()
    if len(header) != 3 or header[1] != b'blob':
        raise RuntimeError('Unreadable staged blob; stop publication')
    size = int(header[2]); data = raw[end+1:end+1+size]; offset = end+size+2
    relative = name[len(prefix):]
    path = Path(relative)
    if (any(part in blocked or '.render' in part for part in path.parts)
        or relative.endswith('.local.json') or path.name in {'local.properties','.flutter-plugins-dependencies'}
        or path.suffix.lower() in {'.apk','.aab','.zip','.m4a','.wav','.mp3','.mp4','.keystore','.jks','.pem','.key','.exe','.dll','.so'}):
        issues.append({'file':relative,'kind':'private_or_generated_path'})
    if size > 20 * 1024**2:
        issues.append({'file':relative,'kind':'unexpected_large_blob'})
    if path.suffix.lower() not in {'.png','.ico','.jar'}:
        try: text = data.decode('utf-8-sig')
        except UnicodeError:
            issues.append({'file':relative,'kind':'unreviewed_binary'}); continue
        for kind, pattern in patterns.items():
            for match in pattern.finditer(text):
                issues.append({'file':relative,'line':text.count('\n',0,match.start())+1,'kind':kind})
    if path.name != 'PUBLIC_SOURCE_MANIFEST.json':
        files.append({'path':relative,'gitBlob':header[0].decode(),
                      'sizeBytes':size,'sha256':hashlib.sha256(data).hexdigest()})
if issues:
    print(json.dumps({'passed':False,'issues':issues},ensure_ascii=False))
    raise SystemExit(1)
if options.write_manifest:
    (project/'PUBLIC_SOURCE_MANIFEST.json').write_text(json.dumps({
        'scope':'audited staged source; not a private workspace backup',
        'excluded':['private media and records','credentials/signing keys','SDK/cache/build state','private document links','legacy work-based demo'],
        'files':files},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'passed':True,'stagedFiles':len(names),'bytes':sum(f['sizeBytes'] for f in files),
                  'manifestUpdated':options.write_manifest},ensure_ascii=False))
