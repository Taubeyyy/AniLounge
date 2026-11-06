#!/usr/bin/env python3
import pathlib
import plistlib
import re
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    info = plistlib.loads(archive.read('Payload/AniLounge.app/Info.plist'))
    assert info['CFBundleIdentifier'] == 'app.anilounge.personal', info
    spec = (pathlib.Path(__file__).resolve().parent.parent / 'project.yml').read_text(encoding='utf-8')
    for setting, field in [('MARKETING_VERSION', 'CFBundleShortVersionString'),
                           ('CURRENT_PROJECT_VERSION', 'CFBundleVersion')]:
        match = re.search(r"^\s*" + setting + r":\s*['\"]?([\d.]+)['\"]?\s*$", spec, re.MULTILINE)
        assert match, f'Missing {setting} in project.yml'
        assert info.get(field) == match.group(1), f'{field}: expected {match.group(1)}, got {info.get(field)}'
    assert tuple(map(int, info['MinimumOSVersion'].split('.'))) <= (16, 4, 1), info
    assert b'aniProgress' in archive.read('Payload/AniLounge.app/PlaybackTracker.js')
    executable = 'Payload/AniLounge.app/' + info['CFBundleExecutable']
    assert archive.getinfo(executable).file_size > 0
    assert archive.read(executable)[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
    print(f"IPA-Struktur, Programmdatei, iOS-Mindestversion und App-Version {info['CFBundleShortVersionString']} (Build {info['CFBundleVersion']}) geprüft.")
