"""Compare the aligned capture-to-render values from two duplex E2E runs."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import NamedTuple


class Sample(NamedTuple):
    conditions: str
    codec: str
    milliseconds: float | None
    band: int | None
    status: str


BANDS = ("合格", "準合格", "要改善", "200 ms超過")


def latency_band(ms: float) -> int:
    return sum(ms > limit for limit in (125, 150, 200))


def load_run(folder: Path) -> dict[tuple[str, str, str], Sample]:
    config = json.loads((folder / "configuration.json").read_text())
    cases = {c["id"]: c for c in json.loads((folder / "scenarios.json").read_text())}
    settings = {k: v for k, v in config.items() if k not in {"run", "expectedMeasurementIDs"}}
    routes = ["local", "webrtc"] if config["transport"] == "all" else [config["transport"]]
    settings.pop("transport")
    if not cases or not set(routes) <= {"local", "webrtc"}:
        raise ValueError("対応する双方向遅延の測定ケースがありません")
    samples = {(route, case, role): Sample("", "", None, None, "記録なし")
               for route in routes for case in cases for role in ("a", "b")}
    seen = set()
    for row in json.loads((folder / "measurements.json").read_text()):
        key = row["transport"], row["scenario"], row["role"]
        if key in seen or key not in samples:
            raise ValueError("測定行の重複または測定条件の不一致")
        seen.add(key)
        codec = row.get("selectedCodec") or "未確認"
        actual = {k: row.get(k) for k in ("selectedCodec", "selectedBitRate", "format", "sampleRate", "fallback",
                                          "localFixture", "remoteFixture", "background")}
        conditions = json.dumps([settings, cases[key[1]], actual], sort_keys=True)
        value = row.get("captureToRenderLatencyWithAllowanceSeconds")
        ms = band = None
        if row.get("expectedSilence") is True:
            status = "対象外（無音）"
        elif row.get("continuityPassed") is False:
            status = "連続性未達"
        elif (row.get("continuityPassed") is not True or row.get("expectedSilence") is not False
              or not isinstance(value, (float, int)) or isinstance(value, bool)
              or not math.isfinite(value) or value < 0):
            status = "未測定"
        else:
            ms = value * 1000
            band = latency_band(ms)
            status = BANDS[band]
        samples[key] = Sample(conditions, codec, ms, band, status)
    return samples


def describe(sample: Sample) -> str:
    return sample.status if sample.milliseconds is None else f"{sample.milliseconds:.3f} ms {sample.status}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("previous", type=Path)
    parser.add_argument("current", type=Path)
    args = parser.parse_args()
    old, new = load_run(args.previous), load_run(args.current)
    print("経路\tケース\t受信端\t実使用codec（前→後）\t前回\t今回\t差分\t判定帯の変化")
    missing = Sample("", "", None, None, "記録なし")
    for key in sorted(old.keys() | new.keys()):
        a, b = old.get(key, missing), new.get(key, missing)
        delta, change = "—", "比較不能"
        if a.conditions and b.conditions and a.conditions != b.conditions:
            change = "条件変更"
        elif a.band is not None and b.status == "連続性未達":
            change = "劣化（連続性）"
        elif a.codec == "未確認" or b.codec == "未確認":
            change = "比較不能"
        elif (a.band is not None and b.band is not None
              and a.milliseconds is not None and b.milliseconds is not None):
            delta = f"{b.milliseconds - a.milliseconds:+.3f} ms"
            change = "劣化" if b.band > a.band else "改善" if b.band < a.band else "同じ帯"
        print(*key, f"{a.codec}→{b.codec}", describe(a), describe(b), delta, change, sep="\t")


if __name__ == "__main__":
    main()
