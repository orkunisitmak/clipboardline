#!/usr/bin/env python3
"""Generate Windows and Linux translations from the shared Apple .strings catalogs."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAIR = re.compile(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;', re.DOTALL)
COMMENTS = re.compile(r'/\*.*?\*/|//[^\n]*', re.DOTALL)


def catalog(source):
    values, end = {}, 0
    for match in PAIR.finditer(source):
        if COMMENTS.sub('', source[end:match.start()]).strip():
            raise ValueError('Unsupported .strings syntax')
        key, value = (json.loads(token) for token in match.groups())
        if key in values:
            raise ValueError('Duplicate localization key')
        values[key] = value
        end = match.end()
    if COMMENTS.sub('', source[end:]).strip() or not values:
        raise ValueError('Incomplete .strings catalog')
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    values = {source.parent.name[:-6]: catalog(source.read_text(encoding='utf-8'))
              for source in sorted((ROOT/'Sources/Tendedero/Resources').glob('*.lproj/Localizable.strings'))}
    content = '// Generated from the shared macOS localization resources.\n(function(root){const catalogs=Object.freeze(' + json.dumps(values, ensure_ascii=False, separators=(',', ':')) + ');if(typeof module===\"object\"&&module.exports)module.exports=catalogs;else root.clipboardLineTranslations=catalogs;})(typeof window===\"object\"?window:globalThis);\n'
    # Both Electron editions, Windows and Linux, ship the same catalogs.
    for target in [ROOT/folder/'locales.js' for folder in ('windows', 'linux') if (ROOT/folder).exists()]:
        if args.check:
            if target.read_text(encoding='utf-8') != content:
                raise SystemExit(target.parent.name.capitalize()+' translations differ; run scripts/sync-windows-locales.py')
        else:
            target.write_text(content, encoding='utf-8')
    print('Shared translation catalogs match: '+str(len(values))+' languages')


if __name__ == '__main__':
    main()
