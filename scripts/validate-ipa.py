#!/usr/bin/env python3
import plistlib
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    info = plistlib.loads(archive.read('Payload/AniLounge.app/Info.plist'))
    assert info['CFBundleIdentifier'] == 'app.anilounge.personal', info
    assert tuple(map(int, info['MinimumOSVersion'].split('.'))) <= (16, 4, 1), info
    assert b'aniProgress' in archive.read('Payload/AniLounge.app/PlaybackTracker.js')
    executable = 'Payload/AniLounge.app/' + info['CFBundleExecutable']
    assert archive.getinfo(executable).file_size > 0
    assert archive.read(executable)[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
    print('IPA-Struktur, Programmdatei und iOS-Mindestversion geprüft.')
