from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from scripts.crash_reports import CrashReports
from scripts.validate import Runner


class CrashReportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.report_dir = self.root / 'reports'
        self.report_dir.mkdir()
        self.output = self.root / 'crash-reports.json'
        self.now = datetime.now(timezone.utc)
        self.monitor = CrashReports(self.output, locations={'macos-user': self.report_dir}, clock=lambda: self.now)

    def write_report(self, process, when, *, name=None, parent='launchd_sim'):
        path = self.report_dir / (name or f'{process}-2026-11-21-130000.ips')
        header = {'app_name': process, 'timestamp': when.isoformat(), 'app_version': '651.32', 'bug_type': '309'}
        body = {'parentProc': parent, 'exception': {'type': 'EXC_CRASH', 'signal': 'SIGABRT'},
                'termination': {'namespace': 'SIGNAL', 'code': 6}, 'secret': 'fixture-secret'}
        path.write_text(json.dumps(header) + '\n' + json.dumps(body))
        return path

    def read_summary(self):
        return json.loads(self.output.read_text())

    def test_delayed_report_uses_event_time_to_find_stage_and_excludes_old_and_unrelated_reports(self):
        self.write_report('PosterBoard', self.now - timedelta(minutes=1))
        with self.monitor.stage('simulator-boot'):
            self.now += timedelta(seconds=2)
            crash_time = self.now
            self.now += timedelta(seconds=1)
        self.now += timedelta(seconds=1)
        with self.monitor.stage('ios-tests'):
            self.write_report('SpringBoard', crash_time)
            self.write_report('icloudmailagent', self.now)
            self.now += timedelta(seconds=1)
        self.monitor.sample()
        summary = self.read_summary()
        self.assertEqual(summary['locations'], {'macos-user': 'readable'})
        self.assertEqual(len(summary['events']), 1)
        event = summary['events'][0]
        self.assertEqual((event['process'], event['stage'], event['runtime']), ('SpringBoard', 'simulator-boot', 'simulator'))
        self.assertEqual((event['signal'], event['termination_namespace'], event['termination_code']), ('SIGABRT', 'SIGNAL', 6))
        self.assertNotIn('fixture-secret', self.output.read_text())

    def test_unavailable_location_and_unreadable_report_are_exposed(self):
        self.monitor.locations['macos-system'] = self.root / 'absent'
        path = self.report_dir / 'RideIntercom-2026-11-21-130000.ips'
        path.write_text('partial')
        self.monitor.sample()
        summary = self.read_summary()
        self.assertEqual(summary['locations']['macos-system'], 'unavailable')
        self.assertEqual(summary['unreadable_reports'], 1)
        self.write_report('RideIntercom', self.now, parent='launchd')
        self.monitor.sample()
        summary = self.read_summary()
        self.assertEqual(summary['unreadable_reports'], 0)
        self.assertEqual(summary['events'][0]['runtime'], 'macos')

    def test_runner_samples_inside_a_long_stage_and_keeps_the_result(self):
        runner = Runner(self.root / 'run', timeout=2, crash_reports=self.monitor)
        with patch('scripts.validate.process_snapshot', return_value={}), \
             patch.object(self.monitor, 'interval_seconds', 0.1), \
             patch.object(self.monitor, 'sample', wraps=self.monitor.sample) as sample:
            self.assertTrue(runner.run('ios-tests', [sys.executable, '-c', 'import time; time.sleep(0.4)']))
            self.assertGreaterEqual(sample.call_count, 3)
        self.assertEqual(self.read_summary()['stages'][0]['name'], 'ios-tests')
