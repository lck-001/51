"""Resumable Google SDK archive fetcher. Metadata must be independently approved."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('--manifest', type=Path, required=True)
parser.add_argument('--cache', type=Path, required=True)
parser.add_argument('--accept-sdk-license', action='store_true')
args = parser.parse_args()
if not args.accept_sdk_license:
    parser.error('Review and accept the Google Android SDK license before fetching packages')
args.cache.mkdir(parents=True, exist_ok=True)
packages = json.loads(args.manifest.read_text(encoding='utf-8-sig'))
if isinstance(packages, dict):
    packages = [packages]

def hash_file(path, algorithm):
    result = hashlib.new(algorithm)
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(4 * 1024**2), b''):
            result.update(data)
    return result.hexdigest()

for package in packages:
    artifact = package['archives'][0]
    url, size = artifact['url'], artifact['sizeBytes']
    algorithm, expected = artifact['algorithm'], artifact['checksum'].lower()
    parsed = urlsplit(url)
    name = parsed.path.rsplit('/', 1)[-1]
    if (parsed.scheme != 'https' or parsed.netloc != 'dl.google.com'
        or not parsed.path.startswith('/android/repository/') or parsed.query
        or not re.fullmatch(r'[A-Za-z0-9_.+-]+\.zip', name)
        or algorithm not in {'sha1','sha256'} or not 0 < size <= 2 * 1024**3
        or not re.fullmatch('[a-f0-9]{40}' if algorithm == 'sha1' else '[a-f0-9]{64}', expected)):
        raise RuntimeError('Unapproved artifact metadata')
    destination = args.cache / name
    if not destination.exists():
        width = (size + 3) // 4
        ranges = [(x, min(x+width, size)-1) for x in range(0, size, width)]

        def transfer(interval):
            first, last = interval
            part = args.cache / f'{name}.{first}-{last}.part'
            current = part.stat().st_size if part.exists() else 0
            length = last-first+1
            if current > length:
                raise RuntimeError('Oversized partial range')
            failures = 0
            while current < length:
                start = first+current
                end = min(start+16*1024**2-1, last)
                tail, header = part.with_suffix('.tail'), part.with_suffix('.headers')
                result = subprocess.run(['curl.exe','--fail','--location','--proto','=https',
                    '--proto-redir','=https','--silent','--show-error','--connect-timeout','15',
                    '--max-time','180','--range',f'{start}-{end}','--max-filesize',str(end-start+1),
                    '--dump-header',str(header),'--output',str(tail),url], check=False)
                headers = header.read_text(encoding='latin-1') if header.exists() else ''
                received = tail.stat().st_size if tail.exists() else 0
                if (not re.search(rf'(?im)^content-range:\s*bytes {start}-{end}/{size}\s*$',headers)
                    or not tail.exists() or received > end-start+1):
                    raise RuntimeError('Invalid range response; preserve prior prefix')
                with part.open('ab') as output, tail.open('rb') as source:
                    for data in iter(lambda: source.read(4*1024**2), b''):
                        output.write(data)
                tail.unlink()
                current = part.stat().st_size
                if result.returncode or received != end-start+1:
                    failures += 1
                    if failures >= 3:
                        raise RuntimeError('Repeated connection failure; prefixes retained')
                else:
                    failures = 0
            print(f'{name}: range complete {first}-{last}', flush=True)
            return first, part

        print(f'Fetching {name} ({size} bytes)', flush=True)
        with ThreadPoolExecutor(max_workers=4) as pool:
            pieces = sorted(pool.map(transfer, ranges))
        assembling = destination.with_suffix('.assembling')
        with assembling.open('wb') as output:
            for _, part in pieces:
                with part.open('rb') as source:
                    for data in iter(lambda: source.read(4*1024**2), b''):
                        output.write(data)
        if assembling.stat().st_size != size or hash_file(assembling, algorithm) != expected:
            raise RuntimeError('Archive integrity failed; do not extract')
        os.replace(assembling, destination)
        for _, part in pieces:
            if part.resolve().parent != args.cache.resolve():
                raise RuntimeError('Cleanup path outside cache')
            part.unlink()
            part.with_suffix('.headers').unlink(missing_ok=True)
    if destination.stat().st_size != size or hash_file(destination, algorithm) != expected:
        raise RuntimeError('Cached archive integrity failed')
    receipt = {'package':package['path'],'revision':package['revision'],'archive':name,
        'sizeBytes':size,'publishedAlgorithm':algorithm,'publishedChecksumMatched':True,
        'localSha256':hash_file(destination,'sha256'),'localSha256IsPublished':algorithm=='sha256'}
    (args.cache/(name+'.verified.json')).write_text(json.dumps(receipt,indent=2),encoding='utf-8')
    print(json.dumps(receipt),flush=True)
