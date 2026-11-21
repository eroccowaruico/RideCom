"""Cases and coverage requirements for network and standalone audio E2E."""

from dataclasses import dataclass
from typing import TypedDict


@dataclass(frozen=True)
class StandaloneAudioPlan:
    tests: tuple[str, ...]
    measurement_ids: tuple[str, ...]
    timeout: int = 180
    preflight: tuple[str, ...] = ()


STANDALONE_AUDIO_PLANS = {
    'pipeline_only': StandaloneAudioPlan(
        tests=('AudioE2ETests/testSpeechContinuityWithoutNetwork',),
        measurement_ids=('pipeline-20ms', 'pipeline-100ms'),
    ),
    'realtime_only': StandaloneAudioPlan(
        tests=('AudioE2ETests/testRealtimeAudioLatencyAndIdentity',),
        measurement_ids=tuple(f'realtime-{fixture}-{codec}'
                              for fixture in ('speech-ja', 'conversation-ja', 'conversation-reply-ja')
                              for codec in ('pcm16', 'opus', 'mpeg4AACELD')),
        timeout=600,
    ),
    'group_only': StandaloneAudioPlan(
        tests=('AudioE2ETests/testEightPersonMixedRouteConversation',),
        measurement_ids=('eight-person-mixed',),
    ),
    'codec_only': StandaloneAudioPlan(
        tests=('AudioE2ETests/testTransmitChainPreservesConversationAndAcknowledgements',
               'AudioE2ETests/testNativeCodecsPreserveWholeSpeech'),
        measurement_ids=('native-codecs', 'transmit-conversations'),
        timeout=600,
    ),
    'switch_limits_only': StandaloneAudioPlan(
        tests=('AudioE2ETests/testMeasureLiveSettingsSwitchLimits',),
        measurement_ids=('switch-limits-2000ms', 'switch-limits-1000ms', 'switch-limits-500ms'),
    ),
    'switches_only': StandaloneAudioPlan(
        tests=('AudioE2ETests/testInputModeChangesRestoreTheSharedReceiveClock',
               'AudioE2ETests/testLiveSettingsKeepBoundedSilenceAndContinuousSteadyAudio'),
        measurement_ids=('live-settings', 'input-mode-recovery'),
        preflight=('AudioE2ETests/testTransmitIsolationRestoresTheSameNoiseReductionAfterBypass',
                   'AudioE2ETests/testReceiveIsolationKeepsItsEffectWhenEnabledAgain'),
    ),
}

MIXED_AUDIO_MEASUREMENT_IDS = ('one-way-initial', 'local-before', 'internet-during', 'local-after')


class AudioCase(TypedDict):
    id: str
    codec: str
    format: str
    bitRate: int
    profile: str
    speaker: bool
    vad: str
    transmitIsolation: bool
    masterIsolation: bool
    peerIsolation: bool
    duck: bool
    masterVolume: float
    peerVolume: float
    localMute: bool
    outputMute: bool
    seconds: int


def scenarios(mode: str, seconds: int) -> list[AudioCase]:
    default: AudioCase = {
        'id': 'default', 'codec': 'mpeg4AACELD', 'format': 'mono48k', 'bitRate': 48000,
        'profile': 'echoCancelledInput', 'speaker': False, 'vad': 'standard', 'transmitIsolation': True,
        'masterIsolation': False, 'peerIsolation': False, 'duck': True, 'masterVolume': 1.0,
        'peerVolume': 1.0, 'localMute': False, 'outputMute': False, 'seconds': seconds
    }
    if mode == 'smoke':
        return [default]
    if mode == 'identity':
        # Both bundled pairs complete at least one full utterance per recording.
        duration = max(20, seconds)
        return [
            {**default, 'id': 'identity-default', 'seconds': duration},
            {
                **default, 'id': 'identity-pcm16', 'codec': 'pcm16', 'transmitIsolation': False,
                'seconds': duration
            },
            {
                **default, 'id': 'identity-opus', 'codec': 'opus', 'transmitIsolation': False,
                'seconds': duration
            },
        ]
    quick: list[AudioCase] = [
        default,
        {
            **default, 'id': 'opus-24k-effects', 'codec': 'opus', 'format': 'mono24k',
            'profile': 'standard', 'vad': 'lowNoise', 'transmitIsolation': False,
            'masterIsolation': True, 'duck': False, 'masterVolume': 0.5, 'peerVolume': 0.5
        },
        {
            **default, 'id': 'pcm16-16k-voicechat', 'codec': 'pcm16', 'format': 'mono16k',
            'profile': 'voiceChat', 'vad': 'noisy', 'peerIsolation': True
        },
        {
            **default, 'id': 'output-mute', 'codec': 'pcm16', 'format': 'mono16k',
            'profile': 'voiceChat', 'outputMute': True, 'seconds': 2
        },
        {
            **default, 'id': 'output-recovery', 'codec': 'pcm16', 'format': 'mono16k',
            'profile': 'voiceChat', 'speaker': True
        },
    ]
    if mode == 'quick':
        return quick
    full: list[AudioCase] = [
        {**default, 'id': f'{codec}-{rate}', 'codec': codec, 'format': rate}
        for codec in ['pcm16', 'opus', 'mpeg4AACELD']
        for rate in ['mono16k', 'mono24k', 'mono48k']
    ]
    full += [
        {
            **default, 'id': f'opus-{rate}-bitrate-{bitrate}', 'codec': 'opus', 'format': rate,
            'bitRate': bitrate
        }
        for rate in ['mono16k', 'mono24k', 'mono48k']
        for bitrate in (48000, 128000)
    ]
    full += [
        {
            **default, 'id': f'AAC-{rate}-bitrate-{bitrate}', 'codec': 'mpeg4AACELD', 'format': rate,
            'bitRate': bitrate
        }
        for rate, limits in [
            ('mono16k', (48000, 48000)),
            ('mono24k', (32000, 64000)),
            ('mono48k', (48000, 128000)),
        ]
        for bitrate in sorted(set(limits))
    ]
    full += quick[1:]
    full += [
        {**default, 'id': 'speaker', 'profile': 'speakerDefault', 'masterVolume': 2.0},
        {**default, 'id': 'speaker-without-explicit-echo', 'profile': 'standard', 'speaker': True},
        {**default, 'id': 'master-zero', 'masterVolume': 0.0, 'seconds': 2},
        {**default, 'id': 'master-recovery'},
        {**default, 'id': 'peer-zero', 'peerVolume': 0.0, 'seconds': 2},
        {**default, 'id': 'peer-recovery'},
        {**default, 'id': 'local-mute', 'localMute': True, 'seconds': 2},
        {**default, 'id': 'local-recovery'},
    ]
    return full
