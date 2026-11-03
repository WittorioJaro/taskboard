#!/usr/bin/env python3
"""Update an existing local Daily Page installation, preserving a backup."""
import argparse
import shutil
from datetime import datetime
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory', type=Path, default=Path.home() / 'Library/Application Support/The Daily Page')
args = parser.parse_args()
server = args.directory / 'server.py'
source = server.read_text()
marker = 'from taskboard_today import today_tasks, toggle_task'
if marker not in source:
    start = source.index('TASKBOARD = Path(')
    end = source.index('W, H, M = ', start)
    backup = server.with_name('server.py.backup-' + datetime.now().strftime('%Y%m%d%H%M%S'))
    shutil.copy2(server, backup)
    server.write_text(source[:start] + marker + '\n\n\n' + source[end:])
    print('Backed up the dashboard server and updated its task source.')
shutil.copy2(Path(__file__).resolve().parents[1] / 'integrations/kindle/taskboard_today.py', args.directory / 'taskboard_today.py')
print('Installed the Today integration. Restart The Daily Page to load it.')
