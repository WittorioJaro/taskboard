"""Shared Today projection for The Daily Page's existing image and tap routes.

Tasks stay in their home board. Dates are local YYYY-MM-DD strings; priorities
are zero-based, with unranked personal Today captures following ranked tasks.
"""
import fcntl
import json
import os
import tempfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

TASKBOARD = Path(os.environ.get('TASKBOARD_FILE', Path.home() / 'Library/Application Support/taskboard/boards.json'))
TASKBOARD_BOARD = os.environ.get('TASKBOARD_BOARD', 'Today')
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=ZoneInfo('UTC'))


def read_taskboard():
    try:
        data = json.loads(TASKBOARD.read_text())
        if not isinstance(data.get('boards'), list):
            return None, None
        board = next((b for b in data['boards']
                      if b.get('title', '').strip().casefold() == TASKBOARD_BOARD.casefold()), None)
        return data, board
    except (OSError, ValueError, AttributeError, TypeError):
        return None, None


def selected_tasks(data, board, now):
    day = now.strftime('%Y-%m-%d')
    midnight = (now.replace(hour=0, minute=0, second=0, microsecond=0) - APPLE_EPOCH).total_seconds()
    tasks = []
    for source in data.get('boards', []):
        personal = board is not None and source['id'] == board['id']
        for task in source.get('tasks', []):
            if not personal and not (TASKBOARD_BOARD.casefold() == 'today' and task.get('plannedFor') == day):
                continue
            if not task.get('title', '').strip():
                continue
            if task.get('isCompleted') and (task.get('completedAt') or 0) < midnight:
                continue
            tasks.append((source, task, personal))
    return sorted(tasks, key=lambda row: row[1].get('todayOrder') if row[1].get('plannedFor') == day and isinstance(row[1].get('todayOrder'), int) else float('inf'))


def deadline_label(task, now):
    value = task.get('dueDate')
    if not isinstance(value, str) or task.get('isCompleted'):
        return ''
    try:
        due = datetime.strptime(value, '%Y-%m-%d').date()
        if due.isoformat() != value:
            return ''
    except ValueError:
        return ''
    remaining = (due - now.date()).days
    if remaining == 0:
        return ' · Due today'
    if remaining == 1:
        return ' · Due tomorrow'
    short = due.strftime('%d %b' if due.year == now.year else '%d %b %Y').lstrip('0')
    return (' · Overdue ' if remaining < 0 else ' · Due ') + short


def today_tasks(now):
    data, board = read_taskboard()
    if data is None:
        return None
    selected = selected_tasks(data, board, now)
    if board is None and not selected:
        return None
    return [{
        'id': task['id'],
        'boardID': source['id'],
        'project': 'Personal' if personal else source['title'],
        'title': ('' if personal else source['title'] + ' · ') + ' '.join(task['title'].split()) + deadline_label(task, now),
        # Split for display: big task name, small project/deadline label above it.
        'name': ' '.join(task['title'].split()),
        'label': ' · '.join(part for part in (
            None if personal else source['title'].strip(),
            deadline_label(task, now).removeprefix(' · ')) if part),
        'done': bool(task.get('isCompleted')),
        'dueDate': task.get('dueDate'),
    } for source, task, personal in selected]


def toggle_task(task_id, now):
    # Same persistent advisory lock as the Mac, held across read + edit + replace.
    # Lock the sidecar, because boards.json's inode changes on atomic replace.
    with TASKBOARD.with_suffix(TASKBOARD.suffix + '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data, board = read_taskboard()
        if data is None:
            return False
        row = next((row for row in selected_tasks(data, board, now) if row[1].get('id') == task_id), None)
        if row is None:
            return False
        source, task, _ = row
        tasks = source['tasks']
        tasks.remove(task)
        if task.get('isCompleted'):
            task['isCompleted'] = False
            task.pop('completedAt', None)
            task.pop('statusOverride', None)
            at = next((i for i, other in enumerate(tasks) if other.get('isCompleted')), len(tasks))
            tasks.insert(at, task)
        else:
            task['isCompleted'] = True
            task['completedAt'] = (now - APPLE_EPOCH).total_seconds()
            task.pop('statusOverride', None)
            tasks.append(task)
        with tempfile.NamedTemporaryFile(mode='w', dir=TASKBOARD.parent, prefix='.kindle-', delete=False) as temp:
            temporary = Path(temp.name)
            try:
                json.dump(data, temp, indent=2, sort_keys=True, ensure_ascii=False)
                temp.flush()
                os.fsync(temp.fileno())
                os.replace(temporary, TASKBOARD)
            finally:
                temporary.unlink(missing_ok=True)
        return True
