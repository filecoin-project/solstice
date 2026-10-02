#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["actionlint-py>=1.7,<2", "shellcheck-py>=0.11,<1"]
# ///
# The exact versions installed are pinned by tools/lint_workflows.py.lock (run with `uv run --locked`); to upgrade,
# raise the ranges above and run `uv lock --script tools/lint_workflows.py`.
"""Lint the GitHub Actions workflows with actionlint, which also runs shellcheck on every `run:` script.

Run from the repo root: `uv run --locked tools/lint_workflows.py`. Extra arguments are passed to actionlint.
The Linter workflow runs the same command.
"""

import os
import subprocess
import sys
from pathlib import Path

# Both packages install their binaries next to this script's interpreter; put that first on PATH so actionlint
# finds this shellcheck rather than whatever the machine has.
bin_dir = Path(sys.executable).parent
env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"}
sys.exit(subprocess.call([bin_dir / "actionlint", *sys.argv[1:]], env=env))
