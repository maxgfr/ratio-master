#!/usr/bin/env bash
# Generate test fixture torrent files
# Requires python3

set -euo pipefail

FIXTURES_DIR="$(cd "$(dirname "$0")/fixtures" && pwd)"

python3 -c "
import os, sys

fixtures_dir = sys.argv[1]

def bencode_str(s):
    if isinstance(s, str):
        s = s.encode('utf-8')
    return str(len(s)).encode() + b':' + s

def bencode_int(i):
    return b'i' + str(i).encode() + b'e'

def bencode_list(items):
    return b'l' + b''.join(items) + b'e'

def bencode_dict(pairs):
    result = b'd'
    for k, v in sorted(pairs):
        result += bencode_str(k) + v
    return result + b'e'

# 1. Simple single-file torrent
info = bencode_dict([
    ('length', bencode_int(104857600)),
    ('name', bencode_str('Test-File')),
    ('piece length', bencode_int(262144)),
    ('pieces', bencode_str(b'a' * 20)),
])
torrent = bencode_dict([
    ('announce', bencode_str('http://tracker.example.com/announce')),
    ('comment', bencode_str('Test torrent')),
    ('info', info),
])
with open(os.path.join(fixtures_dir, 'simple.torrent'), 'wb') as f:
    f.write(torrent)

# 2. Multi-file torrent
files_list = bencode_list([
    bencode_dict([
        ('length', bencode_int(52428800)),
        ('path', bencode_list([bencode_str('file1.txt')])),
    ]),
    bencode_dict([
        ('length', bencode_int(26214400)),
        ('path', bencode_list([bencode_str('subdir'), bencode_str('file2.txt')])),
    ]),
])
info = bencode_dict([
    ('files', files_list),
    ('name', bencode_str('Multi-File-Torrent')),
    ('piece length', bencode_int(524288)),
    ('pieces', bencode_str(b'b' * 20)),
])
torrent = bencode_dict([
    ('announce', bencode_str('http://tracker.example.com/announce')),
    ('info', info),
])
with open(os.path.join(fixtures_dir, 'multifile.torrent'), 'wb') as f:
    f.write(torrent)

# 3. Minimal torrent (bare minimum fields)
info = bencode_dict([
    ('length', bencode_int(1024)),
    ('name', bencode_str('tiny')),
    ('piece length', bencode_int(16384)),
    ('pieces', bencode_str(b'c' * 20)),
])
torrent = bencode_dict([
    ('announce', bencode_str('http://example.com/announce')),
    ('info', info),
])
with open(os.path.join(fixtures_dir, 'minimal.torrent'), 'wb') as f:
    f.write(torrent)

# 4. Large torrent metadata (many fields)
info = bencode_dict([
    ('length', bencode_int(10737418240)),
    ('name', bencode_str('Big-File-10Go')),
    ('piece length', bencode_int(4194304)),
    ('pieces', bencode_str(b'd' * 20)),
])
torrent = bencode_dict([
    ('announce', bencode_str('http://private.tracker.org/announce')),
    ('announce-list', bencode_list([
        bencode_list([bencode_str('http://private.tracker.org/announce')]),
        bencode_list([bencode_str('http://backup.tracker.org/announce')]),
    ])),
    ('comment', bencode_str('A large file for testing')),
    ('created by', bencode_str('ratio-master-tests')),
    ('encoding', bencode_str('UTF-8')),
    ('info', info),
])
with open(os.path.join(fixtures_dir, 'large.torrent'), 'wb') as f:
    f.write(torrent)

# 5. Not a torrent (invalid file)
with open(os.path.join(fixtures_dir, 'invalid.torrent'), 'wb') as f:
    f.write(b'This is not a torrent file')

print('All fixtures generated successfully')
" "$FIXTURES_DIR"
