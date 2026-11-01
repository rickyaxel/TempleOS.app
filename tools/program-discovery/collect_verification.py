#!/usr/bin/env python3
"""Collect actual run evidence without turning partial coverage into a global pass."""
import collections
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'docs/distribution-audit/evidence'


def xctest(path):
    text=path.read_text(errors='replace')
    events=[]
    for m in re.finditer(r"Test Case '-\[([^ ]+) ([^\]]+)\]' (passed|failed|skipped)(?: \(([0-9.]+) seconds\))?",text):
        events.append(dict(test=m[1]+'.'+m[2],status=m[3],seconds=float(m[4]) if m[4] else None))
    starts=len(re.findall(r"Test Suite '(?:All tests|Selected tests)' started",text))
    ends=len(re.findall(r"Test Suite '(?:All tests|Selected tests)' (?:passed|failed)",text))
    return dict(log=str(path.relative_to(ROOT)),counts=dict(collections.Counter(e['status'] for e in events)),tests=events,
                completed=starts>0 and starts==ends,suiteRunsStarted=starts,suiteRunsCompleted=ends,
                note='Method events; nested engine assertions are not counted as separate methods.')


def junit(directory):
    rows=[]
    for f in sorted(directory.glob('TEST-*.xml')):
        root=ET.parse(f).getroot()
        rows.append(dict(suite=root.attrib['name'],tests=int(root.attrib['tests']),failures=int(root.attrib['failures']),
            errors=int(root.attrib['errors']),skipped=int(root.attrib['skipped']),seconds=float(root.attrib['time'])))
    return dict(directory=str(directory.relative_to(ROOT)),suites=rows,
        totals={k:sum(r[k] for r in rows) for k in ['tests','failures','errors','skipped','seconds']})


def main():
    result=dict(campaignScope='Original reconstruction campaign; later authorized hardware follow-ups are separate.',
        physicalDeviceTests=0,policy='Original campaign authorized host tests, iOS simulators and Android emulators only.',
        coverage='Full file/static-reference reconciliation; bounded runtime workflows, not exhaustive dynamic menu or program execution certification.',
        broadFuzzSample=20,xctest=[],junit=[])
    logs=['swift-full-tests.log','swift-bounded-regression.log','swift-corrected-checks.log','ios-phone-ui.log',
        'swift-sprite-regression-final.log','swift-models-memory-final.log','swift-popup-final.log','swift-native-final.log',
        'ios-phone-final.log','ios-phone-verified.log','ios-tablet.log','ios-small.log','ios-metrics.log','ios-foldable/xcodebuild.log',
        'ios-models-complete.log','ios-models-popup-fixed.log','ios-final-navigation.log']
    for log in logs:
        if (OUT/log).is_file():result['xctest'].append(xctest(OUT/log))
    for directory in ['android-core-initial-results','android-core-verified-results','android-purekotlin-verified-results','android-edge-results',
        'android-core-sprite-results','android-purekotlin-sprite-results','android-popup-core-results','android-popup-native-results',
        'android-native-final-results']:
        if (OUT/directory).is_dir():result['junit'].append(junit(OUT/directory))
    for name,path in [('bundle','bundle-validation.json'),('androidUIInitial','android-simulator/report.json'),('androidUI','android-simulator-verified/report.json'),
        ('androidFinalUI','android-final-navigation/report.json'),('androidModels','android-models-popup-fixed/report.json')]:
        if (OUT/path).is_file():result[name]=json.loads((OUT/path).read_text())
    metrics=[]
    for path in sorted((OUT/'ios-metrics').glob('*layout.txt')):
        text=path.read_text()
        if ';perf=' in text:metrics.append(dict(file=str(path.relative_to(ROOT)),value=text.split(';perf=')[1]))
    result['iosPerformanceSamples']=metrics
    native_log=OUT/'swift-native-final.log'
    if native_log.is_file():
        m=re.search(r'fuzz: (\d+) expressions: (\d+) evaluated alike, (\d+) compile errors alike, (\d+) exceptions alike, (\d+) outside the subset, (\d+) mismatches',native_log.read_text(errors='replace'))
        if m:result['finalSwiftNativeFuzz']=dict(zip(['expressions','evaluatedAlike','compileErrorsAlike','exceptionsAlike','outsideSubset','mismatches'],map(int,m.groups())))
    result['screenshots']={label:len(list((OUT/label).rglob('*.png'))) for label in
        ['ios-phone','ios-phone-verified','ios-tablet','ios-small','ios-metrics','ios-foldable/ctl/shots','ios-final-navigation',
         'android-simulator','android-simulator-verified','android-final-navigation','android-models-popup-fixed']}
    followups={}
    for label,path in [('iPhone','iphone-physical/report.json'),('androidNavigation','android-physical/navigation/report.json'),
                       ('androidModels','android-physical/models/report.json')]:
        if (OUT/path).is_file():followups[label]=dict(report=str((OUT/path).relative_to(ROOT)),result=json.loads((OUT/path).read_text()))
    if followups:result['laterOwnerAuthorizedHardwareFollowups']=followups
    (OUT/'verification-summary.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k in ['physicalDeviceTests','screenshots']},indent=2))


if __name__=='__main__':main()
