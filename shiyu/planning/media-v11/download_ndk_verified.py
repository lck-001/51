"""Official NDK download with retained verified-range prefixes; no SDK license edits."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

project = Path(__file__).resolve().parents[2]
metadata = json.loads((project / 'planning/media-v10/android-repository-verified.json').read_text(encoding='utf-8-sig'))
package = next(p for p in metadata['packages'] if p['path'] == 'ndk;28.2.13676358')
archive = next(a for a in package['archives'] if a['hostOs'] == 'windows')
url, size, expected = archive['url'], archive['sizeBytes'], archive['checksum']
if (url != 'https://dl.google.com/android/repository/android-ndk-r28c-windows.zip'
        or size != 748118221 or archive['checksumType'] != 'sha1'):
    raise RuntimeError('Unapproved NDK archive identity')
cache = project / '.toolchains/downloads'
cache.mkdir(exist_ok=True)
target = cache / 'android-ndk-r28c-windows.zip'

def digest(path, algorithm):
    result = hashlib.new(algorithm)
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(4 * 1024**2), b''):
            result.update(data)
    return result.hexdigest()

def transfer(interval):
    start, end = interval
    path = cache / f'ndk-{start}-{end}.part'
    count = path.stat().st_size if path.exists() else 0
    length = end - start + 1
    if count == length:
        return start, path
    if count > length:
        raise RuntimeError('Oversized range; inspect cache')
    tail = path.with_suffix('.tail')
    header = path.with_suffix('.headers')
    failures = 0
    while count < length:
      request_start = start + count
      request_end = min(request_start + 16 * 1024**2 - 1, end)
      requested = request_end-request_start+1
      result = subprocess.run([
        'curl.exe', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
        '--silent', '--show-error', '--connect-timeout', '15', '--max-time', '180',
        '--range', f'{request_start}-{request_end}', '--max-filesize', str(requested),
        '--dump-header', str(header), '--output', str(tail), url,
      ], check=False)
      headers = header.read_text(encoding='latin-1') if header.exists() else ''
      range_ok = re.search(rf'(?im)^content-range:\s*bytes {request_start}-{request_end}/{size}\s*$', headers)
      received = tail.stat().st_size if tail.exists() else 0
      if not range_ok or not tail.exists() or received > requested:
        raise RuntimeError('Range response mismatch; do not assemble')
      with path.open('ab') as out, tail.open('rb') as source:
        for data in iter(lambda: source.read(4 * 1024**2), b''):
            out.write(data)
      tail.unlink()
      count = path.stat().st_size
      if result.returncode != 0 or received != requested:
        failures += 1
        if failures >= 3:
          raise RuntimeError('Three bounded transfers failed; prefixes retained, no extraction')
      else:
        failures = 0
    print(f'NDK range complete: {start}-{end}', flush=True)
    return start, path

if not target.exists():
    width = (size + 3) // 4
    intervals = [(i, min(i + width, size)-1) for i in range(0, size, width)]
    print('Fetching fixed official NDK in four bounded, resumable ranges.', flush=True)
    with ThreadPoolExecutor(max_workers=4) as pool:
        pieces = sorted(pool.map(transfer, intervals))
    merged = target.with_suffix('.assembling')
    with merged.open('wb') as out:
        for _, path in pieces:
            with path.open('rb') as source:
                for data in iter(lambda: source.read(4 * 1024**2), b''):
                    out.write(data)
    if merged.stat().st_size != size or digest(merged, 'sha1') != expected:
        raise RuntimeError('NDK archive does not match official checksum; never extract')
    os.replace(merged, target)
    for _, path in pieces:
        if path.resolve().parent != cache.resolve():
            raise RuntimeError('Range cleanup outside owned cache')
        path.unlink()
        path.with_suffix('.headers').unlink(missing_ok=True)
if target.stat().st_size != size or digest(target, 'sha1') != expected:
    raise RuntimeError('Cached NDK identity mismatch')
receipt = {'archive': target.name, 'sizeBytes': size, 'officialAlgorithm': 'sha1',
           'officialChecksumMatched': True, 'localSha256': digest(target, 'sha256'),
           'localSha256IsOfficialPublishedValue': False, 'installed': False}
output = project / 'planning/media-v11/results/ndk-archive-verified.json'
output.write_text(json.dumps(receipt, indent=2), encoding='utf-8')
print(json.dumps(receipt), flush=True)
