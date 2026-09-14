#!/usr/bin/env python3
"""Replace upstream's trademark in user-visible string VALUES of a materialised
Android tree, every locale, and relabel the rows we repurpose.

    scripts/debrand-strings.py <materialised-tree> "<app name>"

Values only - resource names are lookup keys. Case-sensitive on purpose:
"ownCloud" is the display mark; lowercase "owncloud" is hostnames, package
ids and resource names, which stay. Names that are not display text are
skipped. Fails if a value still carries the mark afterwards.
"""
import pathlib
import re
import sys

SKIP = {"user_agent"}
RELABEL = {"prefs_imprint": "Source code &amp; licences (GPLv3)"}
STRING = re.compile(r'(<string name="(?P<name>[^"]+)"[^>]*>)(?P<value>.*?)(</string>)', re.S)

tree = pathlib.Path(sys.argv[1])
app = sys.argv[2]
files = values = 0
for xml in sorted(tree.glob("owncloudApp/src/main/res/values*/strings.xml")):
    text = xml.read_text(encoding="utf-8")

    def fix(m: "re.Match[str]") -> str:
        global values
        name, value = m.group("name"), m.group("value")
        if name in RELABEL:
            new = RELABEL[name]
        elif name not in SKIP and "ownCloud" in value:
            new = value.replace("ownCloud", app)
        else:
            return m.group(0)
        if new != value:
            values += 1
        return m.group(1) + new + m.group(4)

    new_text = STRING.sub(fix, text)
    if new_text != text:
        xml.write_text(new_text, encoding="utf-8")
        files += 1

print(f"debrand-strings: {values} value(s) in {files} file(s) -> {app!r}")
left = []
for xml in sorted(tree.glob("owncloudApp/src/main/res/values*/strings.xml")):
    for m in STRING.finditer(xml.read_text(encoding="utf-8")):
        if m.group("name") not in SKIP and "ownCloud" in m.group("value"):
            left.append(f"{xml.parent.name}/{m.group('name')}")
if left:
    print("debrand-strings: still branded: " + ", ".join(left[:10]), file=sys.stderr)
    sys.exit(1)
