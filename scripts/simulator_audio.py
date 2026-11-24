"""Select and restore the host audio device for an owned test Simulator."""

from __future__ import annotations

import json
import os
import subprocess
from collections.abc import Callable, Mapping, Sequence


def shared_host_audio_device(devices: Mapping[str, object], host_items: Sequence[Mapping[str, object]],
                             preferred_name: str | None = None) -> str:
    """Return the one 48 kHz host device that both captures and renders.

    The iOS Simulator opens one duplex I/O. Following separate host defaults
    (for example a USB microphone and a display speaker) leaves its native
    input at 0 Hz, so the measurement never reaches the audio path."""
    inputs: dict[str, str] = {}
    outputs: dict[str, str] = {}
    for key, destination in [('inputDevices', inputs), ('outputDevices', outputs)]:
        entries = devices[key]
        if not isinstance(entries, list):
            raise TypeError('Invalid host audio device list')
        for device in entries:
            if not isinstance(device, dict) or not isinstance(device.get('uid'), str) or not isinstance(device.get('name'), str):
                raise TypeError('Invalid host audio device')
            destination[device['uid']] = device['name']
    by_name = {item.get('_name'): item for item in host_items}
    eligible = []
    for uid, name in inputs.items():
        item = by_name.get(name)
        if outputs.get(uid) != name or item is None:
            continue
        device_input = item.get('coreaudio_device_input', 0)
        device_output = item.get('coreaudio_device_output', 0)
        if not isinstance(device_input, (int, float)) or not isinstance(device_output, (int, float)):
            raise TypeError('Invalid host audio channel count')
        if device_input >= 1 and device_output >= 1 and item.get('coreaudio_device_srate') == 48000:
            eligible.append(uid)
    if preferred_name is not None:
        named = [uid for uid in eligible if inputs[uid] == preferred_name]
        if len(named) != 1:
            raise ValueError('RIDEINTERCOM_SIMULATOR_AUDIO_DEVICE must name one 48 kHz audio device with input and output')
        return named[0]
    for default in ('coreaudio_default_audio_input_device', 'coreaudio_default_audio_output_device'):
        preferred = [uid for uid in eligible if default in by_name[inputs[uid]]]
        if len(preferred) == 1:
            return preferred[0]
    if len(eligible) != 1:
        raise ValueError('Connect exactly one 48 kHz host audio device with input and output, '
                         f'or choose one with RIDEINTERCOM_SIMULATOR_AUDIO_DEVICE. Found {len(eligible)} devices.')
    return eligible[0]


def _run_audio_command(args: list[str]) -> Mapping[str, object]:
    output = subprocess.run(args, capture_output=True, text=True, timeout=60, check=True).stdout
    data = json.loads(output)
    result = data.get('result', data) if isinstance(data, dict) and args[0] == 'xcrun' else data
    if not isinstance(result, dict):
        raise TypeError('Invalid audio device command response')
    return result


class SimulatorAudioPin:
    """Pin the owned Simulator's input and output to one host device for a run."""
    def __init__(self, simulator: str,
                 run_json: Callable[[list[str]], Mapping[str, object]] = _run_audio_command) -> None:
        self.simulator = simulator
        self.run_json = run_json
        self.original = None

    @staticmethod
    def _selection(value: object) -> str:
        if value == {'systemDefault': {}}:
            return 'systemDefault'
        # devicectl encodes a pinned device as {"device": {"_0": uid}}.
        uid = value.get('device', {}).get('_0') if isinstance(value, dict) else None
        if not isinstance(uid, str) or not uid:
            raise ValueError('Unrecognized Simulator audio selection: ' + json.dumps(value))
        return uid

    def _info(self) -> Mapping[str, object]:
        return self.run_json(['xcrun', 'devicectl', 'device', 'info', 'audio', '--device', self.simulator, '--json-output', '-'])

    def _select(self, input_device: str, output_device: str) -> None:
        self.run_json(['xcrun', 'devicectl', 'device', 'settings', 'audio', '--device', self.simulator,
                       '--input-device', input_device, '--output-device', output_device, '--json-output', '-'])

    def pin(self) -> str:
        before = self._info()
        original = (self._selection(before['audioInputDevice']), self._selection(before['audioOutputDevice']))
        devices = self.run_json(['xcrun', 'devicectl', 'list', 'audioDevices', '--json-output', '-'])
        groups = self.run_json(['system_profiler', 'SPAudioDataType', '-json'])['SPAudioDataType']
        if not isinstance(groups, list):
            raise TypeError('Invalid host audio inventory')
        host: list[Mapping[str, object]] = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get('_items', []), list):
                raise TypeError('Invalid host audio group')
            for item in group.get('_items', []):
                if not isinstance(item, dict):
                    raise TypeError('Invalid host audio item')
                host.append(item)
        uid = shared_host_audio_device(devices, host, os.environ.get('RIDEINTERCOM_SIMULATOR_AUDIO_DEVICE'))
        self.original = original
        self._select(uid, uid)
        after = self._info()
        if (self._selection(after['audioInputDevice']), self._selection(after['audioOutputDevice'])) != (uid, uid):
            raise RuntimeError('Simulator audio device selection did not apply')
        return uid

    def restore(self) -> None:
        if self.original is None:
            return
        original, self.original = self.original, None
        self._select(*original)
