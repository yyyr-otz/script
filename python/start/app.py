#!/usr/bin/env python3
import subprocess
import sys

subprocess.run("bash start.sh", shell=True, check=True, stdout=sys.stdout, stderr=sys.stderr)
