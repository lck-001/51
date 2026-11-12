"""Generate original local playback fixtures, never speech or pronunciation scores."""
import hashlib
import json
import math
from pathlib import Path
import struct
import wave

root = Path(__file__).resolve().parent / 'fixtures'
root.mkdir(exist_ok=True)
rate = 16000
duration = 12
frames = bytearray()
# Four audible three-second sections: 440 / 660 / 880 / 1100 Hz.
# The last half-second of every section is silent to expose jump boundaries.
for i in range(rate * duration):
    seconds = i / rate
    section = int(seconds // 3)
    phase = seconds % 3
    envelope = min(1.0, phase / .02, max(0, (2.5 - phase) / .02))
    sample = int(0.18 * 32767 * max(0, envelope) * math.sin(2 * math.pi * (440 + section * 220) * seconds))
    frames.extend(struct.pack('<h', sample))
with wave.open(str(root / 'playback-seek-12s.wav'), 'wb') as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(rate)
    out.writeframes(frames)
(root / 'invalid-media.wav').write_bytes(b'RIFF-not-a-valid-audio-container')
(root / 'zero-byte.wav').write_bytes(b'')
(root / '中文 空格 导入说明.txt').write_text('这是专用合成文件，仅检查文件选择和复制。没有用户资料，也没有真实语音。\n', encoding='utf-8')
files = []
for path in sorted(root.iterdir()):
    if path.is_file() and path.name != 'manifest.json':
        files.append({'name': path.name, 'sizeBytes': path.stat().st_size,
                      'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
manifest = {'scope': 'original synthetic local fixtures; no playback executed',
            'wav': {'durationSeconds': 12, 'sampleRate': 16000, 'channels': 1,
                    'sampleBits': 16, 'sectionHz': [440, 660, 880, 1100]}, 'files': files}
(root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({'filesCreated': len(files), 'validWavBytes': len(frames)+44,
                  'mediaPlaybackTested': False}, ensure_ascii=False))
