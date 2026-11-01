#!/usr/bin/env python3
"""Check the real simulator mixer captures against the original WaterFowl opening notes."""
import json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/audio'))
from analyze_capture import read_wav, segment, pitch

def main():
    evidence = ROOT / 'docs/games-preservation/evidence'
    fixture = json.loads((ROOT / 'shared/test-vectors/audio/waterfowl.json').read_text())
    expected = [f for f in fixture['frequencies'] if f > 0][:3]
    rows = []
    for platform in ['ios-phone', 'android-phone']:
        for engine in ['terry', 'native']:
            samples, rate = read_wav(str(evidence / platform / ('waterfowl-' + engine + '.wav')))
            tones = segment(samples, rate)
            trim = int(rate * .002)
            measured = [pitch(samples, rate, a + trim, b - trim) for a, b, _ in tones[:3]]
            assert len(measured) == 3, (platform, engine, 'missing notes')
            errors = [abs(a - b) / b for a, b in zip(measured, expected)]
            peak = max(map(abs, samples))
            silent = all(v == 0 for v in samples[-rate // 10:])
            assert rate == 48000 and peak > .05 and max(errors) < .003 and silent
            rows.append(dict(platform=platform, engine=engine, sampleRate=rate,
                samples=len(samples), seconds=len(samples)/rate, peak=peak,
                firstThreeHz=measured, expectedFirstThreeHz=expected,
                relativePitchErrors=errors, last100msSilent=silent))
    (evidence / 'simulator-audio-analysis.json').write_text(json.dumps(rows, indent=1) + '\n')
    print(json.dumps(rows, indent=1))

if __name__ == '__main__':
    main()
