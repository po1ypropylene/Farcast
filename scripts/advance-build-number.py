#!/usr/bin/env python3
"""Reserve the next app build number without changing the marketing version."""
import fcntl
from pathlib import Path
import re


def advance(path: Path) -> int:
    # Serialise reservations by the production and screenshot build scripts.
    with path.open('r+') as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        source = file.read()
        pattern = r'^(CURRENT_PROJECT_VERSION\s*=\s*)([1-9][0-9]*)([ \t]*)$'
        matches = list(re.finditer(pattern, source, re.MULTILINE))
        declarations = re.findall(r'^\s*CURRENT_PROJECT_VERSION\s*=', source, re.MULTILINE)
        if len(matches) != 1 or len(declarations) != 1:
            raise ValueError('Expected one positive integer build number in Version.xcconfig')
        match = matches[0]
        number = int(match[2]) + 1
        updated = source[:match.start(2)] + str(number) + source[match.end(2):]
        file.seek(0)
        file.write(updated)
        file.truncate()
        return number


if __name__ == '__main__':
    print(f'App build number: {advance(Path(__file__).resolve().parents[1] / "Version.xcconfig")}')
