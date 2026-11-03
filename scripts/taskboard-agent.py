#!/usr/bin/env python3
"""Read and edit taskboard using a separately granted Firebase agent account."""
import argparse
import json
import os
import sys
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

APPLE_EPOCH = 978307200
# Python.org's macOS builds may not have installed their default CA symlink.
try:
    import certifi
    TLS_CONTEXT = ssl.create_default_context(cafile=certifi.where())
except ImportError:
    TLS_CONTEXT = ssl.create_default_context()


def request_json(url, method='GET', body=None, headers=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method,
                                     headers={'Content-Type': 'application/json', **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=30, context=TLS_CONTEXT) as response:
            return json.load(response), response.headers
    except urllib.error.HTTPError as error:
        # Never include the request URL: it contains the short-lived ID token.
        raise RuntimeError(f'Firebase HTTP {error.code}') from None
    except urllib.error.URLError:
        raise RuntimeError('Could not reach Firebase') from None


class AgentClient:
    def __init__(self, config):
        self.config = config
        auth, _ = request_json('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=' +
                               urllib.parse.quote(config['apiKey']), 'POST', {
                                   'email': config['email'], 'password': config['password'], 'returnSecureToken': True,
                               })
        owner = urllib.parse.quote(config['ownerUID'], safe='')
        self.url = (config['databaseURL'].rstrip('/') + '/taskboardSnapshots/' + owner + '.json?auth=' +
                    urllib.parse.quote(auth['idToken'], safe=''))

    def read(self):
        envelope, headers = request_json(self.url, headers={'X-Firebase-ETag': 'true'})
        if not isinstance(envelope, dict) or not isinstance(envelope.get('payload'), dict):
            raise ValueError('The owner snapshot does not exist')
        payload = envelope['payload']
        payload['boards'] = payload.get('boards') or []
        for board in payload['boards']:
            board['tasks'] = board.get('tasks') or []
        return envelope, headers['ETag']

    def mutate(self, operation):
        for _ in range(8):
            envelope, etag = self.read()
            operation(envelope['payload'])
            envelope['updatedAt'] = max(int(time.time() * 1000), envelope.get('updatedAt', 0) + 1)
            try:
                request_json(self.url, 'PUT', envelope, {'if-match': etag})
                return envelope['payload']
            except RuntimeError as error:
                if str(error) != 'Firebase HTTP 412':
                    raise
        raise RuntimeError('The board changed repeatedly. Retry the command.')


def find_board(snapshot, identifier):
    matches = [board for board in snapshot['boards'] if board['id'].lower() == identifier.lower()]
    if not matches:
        matches = [board for board in snapshot['boards'] if board['title'].casefold() == identifier.casefold()]
    if len(matches) != 1:
        raise ValueError('Use a unique board ID or board title')
    return matches[0]


def find_task(snapshot, identifier):
    matches = [(board, task) for board in snapshot['boards'] for task in board['tasks']
               if task['id'].lower() == identifier.lower()]
    if len(matches) != 1:
        raise ValueError('Task ID was not found or is duplicated')
    return matches[0]


def is_today(board):
    return board['title'].strip().casefold() == 'today'


def today(snapshot, day):
    return sorted([{'boardID': board['id'], 'project': 'Personal' if is_today(board) else board['title'], **task}
                   for board in snapshot['boards'] for task in board['tasks']
                   if is_today(board) or task.get('plannedFor') == day],
                  key=lambda task: task.get('todayOrder') if task.get('plannedFor') == day and isinstance(task.get('todayOrder'), int) else float('inf'))


def parse_day(value):
    try:
        parsed = date.fromisoformat(value)
        if parsed.isoformat() != value:
            raise ValueError
        return parsed
    except (TypeError, ValueError):
        raise ValueError('Use a valid YYYY-MM-DD date') from None


def deadlines(snapshot, day):
    reference = parse_day(day)
    result = []
    for board in snapshot['boards']:
        for task in board['tasks']:
            if task.get('isCompleted') or not task.get('dueDate'):
                continue
            try:
                due = parse_day(task['dueDate'])
            except ValueError:
                continue
            remaining = (due - reference).days
            result.append({**task, 'boardID': board['id'],
                           'project': 'Personal' if is_today(board) else board['title'],
                           'daysUntilDue': remaining,
                           'deadlineStatus': 'overdue' if remaining < 0 else 'dueToday' if remaining == 0 else 'upcoming'})
    return sorted(result, key=lambda task: task['dueDate'])


def new_board(title, identifier=None):
    return {'id': identifier or str(uuid.uuid4()).upper(), 'title': title, 'themeID': 'sunrise' if title == 'Today' else 'cobalt',
            'folderPath': '', 'createdAt': time.time() - APPLE_EPOCH, 'isExpanded': True, 'isPinned': False, 'tasks': []}


def apply_command(snapshot, args, day, identifier):
    if args.command == 'add-board':
        title = args.title.strip()
        if not title:
            raise ValueError('Board title cannot be empty')
        snapshot['boards'].append(new_board(title, identifier))
    elif args.command == 'add-task':
        title = args.title.strip()
        if not title:
            raise ValueError('Task title cannot be empty')
        board = find_board(snapshot, args.board)
        due = getattr(args, 'due', None)
        if due is not None:
            parse_day(due)
        task = {'id': identifier, 'title': title, 'createdAt': time.time() - APPLE_EPOCH,
                'isCompleted': False, 'attachments': []}
        if due is not None:
            task['dueDate'] = due
        board['tasks'].append(task)
    elif args.command == 'plan':
        identifiers = [value.lower() for value in args.tasks]
        if len(set(identifiers)) != len(identifiers):
            raise ValueError('Each task may appear only once in a plan')
        selected = [find_task(snapshot, value) for value in identifiers]
        if any(task.get('isCompleted') for _, task in selected):
            raise ValueError('Completed tasks cannot be planned')
        for board in snapshot['boards']:
            for task in board['tasks']:
                if task.get('plannedFor') == day:
                    task.pop('plannedFor', None)
                    task.pop('todayOrder', None)
        for order, (_, task) in enumerate(selected):
            task['plannedFor'], task['todayOrder'] = day, order
        if not any(is_today(board) for board in snapshot['boards']):
            snapshot['boards'].insert(0, new_board('Today', identifier))
    elif args.command == 'deadline':
        _, task = find_task(snapshot, args.task)
        if args.due.casefold() == 'none':
            task.pop('dueDate', None)
        else:
            parse_day(args.due)
            task['dueDate'] = args.due
    elif args.command == 'unplan':
        _, task = find_task(snapshot, args.task)
        task.pop('plannedFor', None)
        task.pop('todayOrder', None)
    elif args.command == 'complete':
        _, task = find_task(snapshot, args.task)
        task['isCompleted'] = True
        task['completedAt'] = time.time() - APPLE_EPOCH
        task.pop('statusOverride', None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=os.environ.get('TASKBOARD_AGENT_CONFIG'),
                        help='Private agent credentials JSON (or TASKBOARD_AGENT_CONFIG)')
    parser.add_argument('--timezone', default='Europe/Warsaw')
    parser.add_argument('--date', help='Plan date, YYYY-MM-DD; defaults to today in --timezone')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('read')
    commands.add_parser('today')
    commands.add_parser('deadlines', help='Open tasks with deadlines, earliest first, including overdue tasks')
    add_board = commands.add_parser('add-board'); add_board.add_argument('title')
    add_task = commands.add_parser('add-task'); add_task.add_argument('--board', required=True); add_task.add_argument('--title', required=True)
    add_task.add_argument('--due', help='Optional deadline, YYYY-MM-DD')
    deadline = commands.add_parser('deadline', help='Set or remove a task deadline')
    deadline.add_argument('task')
    deadline.add_argument('due', help='YYYY-MM-DD, or none to remove')
    plan = commands.add_parser('plan'); plan.add_argument('tasks', nargs='*', help='Task IDs in priority order; empty clears the dated plan')
    for command in ('unplan', 'complete'):
        child = commands.add_parser(command); child.add_argument('task')
    args = parser.parse_args()
    if args.config is None:
        parser.error('Provide --config or TASKBOARD_AGENT_CONFIG')
    try:
        day = args.date or datetime.now(ZoneInfo(args.timezone)).strftime('%Y-%m-%d')
        parse_day(day)
        config = json.loads(Path(args.config).read_text())
        client = AgentClient(config)
        if args.command in ('read', 'today', 'deadlines'):
            snapshot = client.read()[0]['payload']
            result = snapshot if args.command == 'read' else deadlines(snapshot, day) if args.command == 'deadlines' else today(snapshot, day)
            print(json.dumps(result, indent=2))
        else:
            identifier = str(uuid.uuid4()).upper()
            client.mutate(lambda snapshot: apply_command(snapshot, args, day, identifier))
            print(json.dumps({'ok': True, **({'id': identifier} if args.command.startswith('add-') else {})}))
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        # KeyError may identify a missing config field; never print config data.
        print(str(error) if isinstance(error, (RuntimeError, ValueError)) else 'Check the private agent configuration file.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
