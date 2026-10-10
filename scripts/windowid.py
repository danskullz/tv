#!/usr/bin/env python3
"""Prints the CGWindowID of the first on-screen window belonging to a process name.

`screencapture -l` wants a CGWindowID, which System Events does not expose. Quartz lives in
pyobjc, which is not guaranteed to be installed, so this builds a tiny Swift helper on first use
and caches it next to the script.

    scripts/windowid.py Marquee
"""
import os
import subprocess
import sys

name = sys.argv[1] if len(sys.argv) > 1 else "Marquee"
here = os.path.dirname(os.path.abspath(__file__))
binary = os.path.join(here, ".windowid")
source = os.path.join(here, "windowid.swift")

if not os.path.exists(binary):
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["swiftc", "-O", source, "-o", binary], check=True, env=env)

sys.exit(subprocess.run([binary, name]).returncode)