import copy
import importlib.util
import json
import tempfile
import unittest
from argparse import Namespace
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


kindle = load_module('kindle_today', ROOT / 'integrations/kindle/taskboard_today.py')
agent = load_module('agent', ROOT / 'scripts/taskboard-agent.py')
NOW = datetime(2026, 10, 31, 20, tzinfo=ZoneInfo('Europe/Warsaw'))


class TodayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        kindle.TASKBOARD = Path(self.temp.name) / 'boards.json'
        self.snapshot = {'boards': [
            {'id': 'personal', 'title': 'Today', 'tasks': [{'id': 'legacy', 'title': 'Personal capture', 'isCompleted': False}]},
            {'id': 'project', 'title': 'Project', 't3ProjectID': 't3-original', 'tasks': [
                {'id': 'task', 'title': 'Project task', 'isCompleted': False, 'attachments': [{'path': 'image.png'}]},
                {'id': 'other', 'title': 'Other task', 'isCompleted': False},
            ]},
        ]}

    def write(self):
        kindle.TASKBOARD.write_text(json.dumps(self.snapshot))

    def test_agent_plan_keeps_home_board_and_kindle_completes_original(self):
        agent.apply_command(self.snapshot, Namespace(command='plan', tasks=['task']), '2026-10-31', 'unused')
        self.assertEqual(len(self.snapshot['boards'][0]['tasks']), 1)
        self.assertEqual(self.snapshot['boards'][1]['t3ProjectID'], 't3-original')
        self.write()
        rows = kindle.today_tasks(NOW)
        self.assertEqual([task['id'] for task in rows], ['task', 'legacy'])
        self.assertEqual(rows[0]['title'], 'Project · Project task')
        self.assertEqual((rows[0]['name'], rows[0]['label']), ('Project task', 'Project'))
        self.assertEqual((rows[1]['name'], rows[1]['label']), ('Personal capture', ''))
        self.assertTrue(kindle.toggle_task('task', NOW))
        saved = json.loads(kindle.TASKBOARD.read_text())
        task = next(t for t in saved['boards'][1]['tasks'] if t['id'] == 'task')
        self.assertTrue(task['isCompleted'])
        self.assertEqual(task['plannedFor'], '2026-10-31')
        self.assertEqual(task['attachments'], [{'path': 'image.png'}])
        self.assertTrue(kindle.toggle_task('task', NOW))
        saved = json.loads(kindle.TASKBOARD.read_text())
        task = next(t for t in saved['boards'][1]['tasks'] if t['id'] == 'task')
        self.assertFalse(task['isCompleted'])
        self.assertNotIn('completedAt', task)

    def test_unselected_and_expired_tasks_are_not_toggled(self):
        self.snapshot['boards'][1]['tasks'][0]['plannedFor'] = '2026-10-30'
        self.write()
        self.assertFalse(kindle.toggle_task('task', NOW))
        self.assertFalse(kindle.toggle_task('other', NOW))
        self.assertEqual([t['id'] for t in kindle.today_tasks(NOW)], ['legacy'])

    def test_new_plan_replaces_date_selection_and_orders_without_copying(self):
        agent.apply_command(self.snapshot, Namespace(command='plan', tasks=['task', 'other']), '2026-10-31', 'unused')
        agent.apply_command(self.snapshot, Namespace(command='plan', tasks=['other']), '2026-10-31', 'unused')
        project = self.snapshot['boards'][1]
        self.assertEqual([t['id'] for t in project['tasks']], ['task', 'other'])
        self.assertNotIn('plannedFor', project['tasks'][0])
        self.assertEqual(project['tasks'][1]['todayOrder'], 0)
        self.write()
        self.assertEqual([t['id'] for t in kindle.today_tasks(NOW)], ['other', 'legacy'])

    def test_completed_yesterday_is_hidden_but_completed_today_can_be_undone(self):
        personal = self.snapshot['boards'][0]['tasks'][0]
        personal['isCompleted'] = True
        personal['completedAt'] = (NOW - kindle.APPLE_EPOCH).total_seconds() - 86400
        self.write()
        self.assertEqual(kindle.today_tasks(NOW), [])
        personal['completedAt'] = (NOW - kindle.APPLE_EPOCH).total_seconds()
        self.write()
        self.assertTrue(kindle.today_tasks(NOW)[0]['done'])

    def test_deadline_edit_preserves_plan_and_rejects_invalid_dates(self):
        agent.apply_command(self.snapshot, Namespace(command='plan', tasks=['task']), '2026-10-31', 'unused')
        agent.apply_command(self.snapshot, Namespace(command='deadline', task='task', due='2026-11-04'), '2026-10-31', 'unused')
        task = self.snapshot['boards'][1]['tasks'][0]
        self.assertEqual(task['plannedFor'], '2026-10-31')
        self.assertEqual(task['dueDate'], '2026-11-04')
        for invalid in ['2026-02-29', '2026-02-30', '2026-2-01', '20261104', '2026-11-04T00:00:00Z']:
            with self.assertRaises(ValueError):
                agent.apply_command(self.snapshot, Namespace(command='deadline', task='task', due=invalid), '2026-10-31', 'unused')
            self.assertEqual(task['dueDate'], '2026-11-04')
        agent.apply_command(self.snapshot, Namespace(command='deadline', task='task', due='none'), '2026-10-31', 'unused')
        self.assertNotIn('dueDate', task)
        self.assertEqual(task['plannedFor'], '2026-10-31')

    def test_agent_deadlines_sort_and_classify_only_open_dated_tasks(self):
        tasks = self.snapshot['boards'][1]['tasks']
        tasks[0]['dueDate'] = '2026-11-01'
        tasks[1]['dueDate'] = '2026-10-30'
        tasks.extend([
            {'id': 'due-today', 'title': 'Due today', 'isCompleted': False, 'dueDate': '2026-10-31'},
            {'id': 'done', 'title': 'Done', 'isCompleted': True, 'dueDate': '2026-10-01'},
            {'id': 'invalid', 'title': 'Invalid date', 'isCompleted': False, 'dueDate': '2026-02-30'},
        ])
        result = agent.deadlines(self.snapshot, '2026-10-31')
        self.assertEqual([t['id'] for t in result], ['other', 'due-today', 'task'])
        self.assertEqual([t['deadlineStatus'] for t in result], ['overdue', 'dueToday', 'upcoming'])
        self.assertEqual([t['daysUntilDue'] for t in result], [-1, 0, 1])
        self.assertTrue(all(t['project'] == 'Project' for t in result))

    def test_kindle_shows_deadline_and_completion_preserves_it(self):
        agent.apply_command(self.snapshot, Namespace(command='plan', tasks=['task']), '2026-10-31', 'unused')
        task = self.snapshot['boards'][1]['tasks'][0]
        task['dueDate'] = '2026-10-30'
        self.write()
        self.assertIn('Overdue', kindle.today_tasks(NOW)[0]['title'])
        self.assertTrue(kindle.today_tasks(NOW)[0]['label'].startswith('Project · Overdue'))
        self.assertTrue(kindle.toggle_task('task', NOW))
        saved = json.loads(kindle.TASKBOARD.read_text())
        dated = next(t for t in saved['boards'][1]['tasks'] if t['id'] == 'task')
        self.assertEqual(dated['dueDate'], '2026-10-30')
        self.assertTrue(kindle.toggle_task('task', NOW))
        self.assertEqual(next(t for t in kindle.today_tasks(NOW) if t['id'] == 'task')['dueDate'], '2026-10-30')

    def test_agent_creates_task_with_deadline_in_original_board(self):
        agent.apply_command(self.snapshot, Namespace(command='add-task', board='Project', title='New task', due='2026-11-04'), '2026-10-31', 'new-id')
        self.assertEqual(self.snapshot['boards'][1]['tasks'][-1]['dueDate'], '2026-11-04')
        self.assertEqual(len(self.snapshot['boards'][0]['tasks']), 1)

    def test_agent_retries_etag_conflict_against_fresh_snapshot(self):
        client = agent.AgentClient.__new__(agent.AgentClient)
        client.url = 'test-url'
        external = copy.deepcopy(self.snapshot)
        external['boards'][1]['tasks'][0]['title'] = 'Renamed on Mac'
        reads = iter([(copy.deepcopy({'payload': self.snapshot}), 'old'), ({'payload': external}, 'new')])
        client.read = lambda: next(reads)
        original = agent.request_json
        writes = []
        def write(url, method, envelope, headers):
            writes.append(copy.deepcopy(envelope))
            if len(writes) == 1:
                raise RuntimeError('Firebase HTTP 412')
            return envelope, {}
        agent.request_json = write
        try:
            client.mutate(lambda snapshot: agent.apply_command(snapshot, Namespace(command='plan', tasks=['task']), '2026-10-31', 'unused'))
        finally:
            agent.request_json = original
        task = writes[1]['payload']['boards'][1]['tasks'][0]
        self.assertEqual(task['title'], 'Renamed on Mac')
        self.assertEqual(task['plannedFor'], '2026-10-31')


if __name__ == '__main__':
    unittest.main()
