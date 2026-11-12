"""Bounded resumable range download of the single pinned official SDK archive."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DOWNLOADS = ROOT / '.toolchains' / 'downloads'
META = json.loads((Path(__file__).parent / 'flutter-release-verified.json').read_text(encoding='utf-8-sig'))
URL = META['archiveUrl']
SIZE = META['sizeBytes']
EXPECTED = META['sha256']
if URL != 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.50.0-stable.zip':
    raise RuntimeError('Unapproved archive URL')
if SIZE != 1868535132 or SIZE > 3 * 1024**3:
    raise RuntimeError('Unexpected length')
DOWNLOADS.mkdir(parents=True, exist_ok=True)
partial = DOWNLOADS / 'flutter_windows_3.50.0-stable.zip.partial'
prefix = partial.stat().st_size if partial.exists() else 0
if prefix > SIZE:
    raise RuntimeError('Oversized partial, inspect before retry')
if prefix == SIZE:
    print('Complete partial exists; caller must verify full SHA256.', flush=True)
    raise SystemExit(0)

workers = 6
width = (SIZE - prefix + workers - 1) // workers
ranges = [(start, min(start + width, SIZE) - 1) for start in range(prefix, SIZE, width)]

def transfer(interval):
    start, end = interval
    path = DOWNLOADS / f'flutter-{start}-{end}.chunk'
    headers = path.with_suffix('.headers')
    length = end - start + 1
    # A previous complete range may be reused; the final archive hash remains mandatory.
    if path.exists() and path.stat().st_size == length and headers.exists():
        text = headers.read_text(encoding='latin-1')
        if re.search(rf'(?im)^content-range:\s*bytes {start}-{end}/{SIZE}\s*$', text):
            return start, path
    existing = 0
    if path.exists() and headers.exists() and 0 < path.stat().st_size < length:
        original_headers = headers.read_text(encoding='latin-1')
        if re.search(rf'(?im)^content-range:\s*bytes {start}-{end}/{SIZE}\s*$', original_headers):
            existing = path.stat().st_size
    request_start = start + existing
    output = path.with_suffix('.tail') if existing else path
    response_headers = path.with_suffix('.tail-headers') if existing else headers
    remaining = length - existing
    result = subprocess.run([
        'curl.exe', '--fail', '--location', '--proto', '=https', '--silent', '--show-error',
        '--connect-timeout', '15', '--max-time', '1800', '--max-filesize', str(remaining),
        '--range', f'{request_start}-{end}', '--dump-header', str(response_headers), '--output', str(output), URL,
    ], check=False)
    text = response_headers.read_text(encoding='latin-1') if response_headers.exists() else ''
    range_ok = bool(re.search(rf'(?im)^content-range:\s*bytes {request_start}-{end}/{SIZE}\s*$', text))
    if existing and range_ok and output.exists() and output.stat().st_size <= remaining:
        # Retain verified-range prefix bytes even if the bounded transfer times out.
        with path.open('ab') as target, output.open('rb') as stream:
            for block in iter(lambda: stream.read(4 * 1024**2), b''):
                target.write(block)
        output.unlink()
        response_headers.unlink(missing_ok=True)
    if result.returncode != 0:
        raise RuntimeError(f'Range transfer stopped with curl {result.returncode}; valid prefix retained: {start}-{end}')
    text = headers.read_text(encoding='latin-1')
    if (path.stat().st_size != length or
            not re.search(rf'(?im)^content-range:\s*bytes {start}-{end}/{SIZE}\s*$', text)):
        raise RuntimeError(f'Range not satisfied: {start}-{end}')
    print(f'Completed range {start}-{end} ({length} bytes)', flush=True)
    return start, path

print(f'Preserving {prefix} downloaded bytes; fetching {len(ranges)} remaining ranges.', flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
    pieces = sorted(executor.map(transfer, ranges))
assembled = partial.with_suffix('.assembling')
digest = hashlib.sha256()
with assembled.open('wb') as target:
    inputs = ([partial] if prefix else []) + [p for _, p in pieces]
    for source in inputs:
        with source.open('rb') as stream:
            for block in iter(lambda: stream.read(4 * 1024**2), b''):
                digest.update(block)
                target.write(block)
if assembled.stat().st_size != SIZE or digest.hexdigest() != EXPECTED:
    raise RuntimeError('Assembled archive identity mismatch; do not extract')
os.replace(assembled, partial)
# Only these exact, task-owned range files are removed after full hash verification.
for _, path in pieces:
    for owned in (path, path.with_suffix('.headers')):
        if owned.resolve().parent != DOWNLOADS.resolve():
            raise RuntimeError('Cleanup outside download directory')
        owned.unlink(missing_ok=True)
print('Assembled archive matches the official SHA256.', flush=True)
