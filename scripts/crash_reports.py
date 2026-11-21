"""Collect bounded crash metadata for a single local validation run."""
from __future__ import annotations

import json
import re
import stat
import sys
from collections.abc import Callable, Generator, Mapping
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import TypedDict
from uuid import UUID

REPORT_NAME = re.compile(
    r'(RideIntercom(?:Watch|Widgets|UITests|WatchUITests|AudioE2EHost|AudioE2ETests)?(?:-Runner)?'
    r'|PosterBoard|SpringBoard|Xcode|xcodebuild|Simulator|SimulatorTrampoline|CoreSimulatorService'
    r'|simctl|dtdeviceinfod|testmanagerd|xctest|XCTRunner)-\d{4}-\d{2}-\d{2}-.*\.ips\Z'
)
MAX_EVENTS = 32
MAX_REPORT_BYTES = 2 * 1024 * 1024


class Stage(TypedDict):
    name: str
    started_at: str
    finished_at: str | None


class CrashEvent(TypedDict):
    occurred_at: str
    process: str
    location: str
    runtime: str
    version: str | None
    simulator_related: bool
    exception: str | None
    signal: str | None
    termination_namespace: str | None
    termination_code: int | None


class ObservedCrash(CrashEvent):
    stage: str | None


class CrashSummary(TypedDict):
    started_at: str
    observed_at: str
    locations: dict[str, str]
    stages: list[Stage]
    events: list[ObservedCrash]
    truncated: bool
    unreadable_reports: int


def identifier(value: object) -> str | None:
    return value if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', value) else None


class CrashReports:
    interval_seconds = 15

    def __init__(self, output: Path, *, locations: Mapping[str, Path] | None = None,
                 clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> None:
        self.output = Path(output)
        self.locations = dict(locations) if locations is not None else {
            'macos-user': Path.home() / 'Library/Logs/DiagnosticReports',
            'macos-system': Path('/Library/Logs/DiagnosticReports'),
        }
        self.clock = clock
        self.started_at = clock()
        self.stages: list[Stage] = []
        self.events: dict[tuple[str, str], CrashEvent] = {}
        self.truncated = False
        self.write_failed = False

    def add_simulator(self, sim: str) -> None:
        uid = str(UUID(sim)).upper()
        devices = Path.home() / 'Library/Developer/CoreSimulator/Devices'
        self.locations['simulator-' + uid] = devices / uid / 'data/Library/Logs/CrashReporter'

    @contextmanager
    def stage(self, name: str) -> Generator[None, None, None]:
        stage: Stage = {'name': name, 'started_at': self.clock().isoformat(), 'finished_at': None}
        self.stages.append(stage)
        self.sample()
        try:
            yield
        finally:
            stage['finished_at'] = self.clock().isoformat()
            self.sample()

    def read_event(self, path: Path, process: str, location: str, now: datetime) -> CrashEvent | None:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mtime < self.started_at.timestamp():
            return None
        with path.open('rb') as report:
            header = json.loads(report.readline(8192))
            if header['app_name'] != process:
                raise ValueError('report process does not match its file name')
            when = datetime.fromisoformat(header['timestamp'])
            if when.tzinfo is None:
                raise ValueError('report timestamp is missing a timezone')
            if not self.started_at <= when <= now:
                return None
            raw = report.read(MAX_REPORT_BYTES + 1)
            if len(raw) > MAX_REPORT_BYTES:
                raise ValueError('report body exceeds the read limit')
            body = json.loads(raw)
        exception = body.get('exception', {})
        termination = body.get('termination', {})
        code = termination.get('code')
        runtime = 'simulator' if location.startswith('simulator-') or body.get('parentProc') == 'launchd_sim' else 'macos'
        return {
            'occurred_at': when.astimezone(timezone.utc).isoformat(), 'process': process, 'location': location,
            'runtime': runtime, 'version': identifier(header.get('app_version')),
            'simulator_related': body.get('responsibleProc') == 'SimulatorTrampoline' or runtime == 'simulator',
            'exception': identifier(exception.get('type')), 'signal': identifier(exception.get('signal')),
            'termination_namespace': identifier(termination.get('namespace')),
            'termination_code': code if type(code) is int else None,
        }

    def sample(self) -> None:
        now = self.clock()
        states = {}
        unreadable = 0
        for location, root in self.locations.items():
            try:
                for path in root.iterdir():
                    match = REPORT_NAME.fullmatch(path.name)
                    key = (location, path.name)
                    if not match or key in self.events or self.truncated:
                        continue
                    try:
                        event = self.read_event(path, match[1], location, now)
                    except (OSError, ValueError, KeyError, TypeError, AttributeError):
                        unreadable += 1
                        continue
                    if event is not None:
                        if len(self.events) >= MAX_EVENTS:
                            self.truncated = True
                        else:
                            self.events[key] = event
                states[location] = 'readable'
            except OSError:
                states[location] = 'unavailable'
        events: list[ObservedCrash] = []
        for event in sorted(self.events.values(), key=lambda item: item['occurred_at']):
            when = datetime.fromisoformat(event['occurred_at'])
            stage = next((s['name'] for s in reversed(self.stages)
                          if datetime.fromisoformat(s['started_at']) <= when <=
                          (datetime.fromisoformat(s['finished_at']) if s['finished_at'] else now)), None)
            events.append({**event, 'stage': stage})
        summary: CrashSummary = {'started_at': self.started_at.isoformat(), 'observed_at': now.isoformat(), 'locations': states,
                   'stages': self.stages, 'events': events, 'truncated': self.truncated, 'unreadable_reports': unreadable}
        try:
            temporary = self.output.with_suffix('.tmp')
            temporary.write_text(json.dumps(summary, indent=2) + '\n')
            temporary.replace(self.output)
        except OSError:
            if not self.write_failed:
                print('Crash report observation could not be saved.', file=sys.stderr, flush=True)
                self.write_failed = True
