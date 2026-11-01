#!/usr/bin/env python3
"""Run a real audit command with its output and machine-readable completion status.

--detach lets long device suites survive a chat/tool session interruption. A log
without a completion JSON is interrupted/unknown, never a passing test result.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--detach', action='store_true')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('A command is required after --')
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if args.detach:
        worker_args = sys.argv[1:].copy()
        worker_args.remove('--detach')
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), *worker_args],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        print(json.dumps({'pid': process.pid, 'log': str(output) + '.log'}))
        return 0
    result = {'command': command, 'cwd': str(Path.cwd()),
              'started_utc': datetime.now(timezone.utc).isoformat(), 'status': 'RUNNING'}
    status = output.with_suffix('.json')
    status.write_text(json.dumps(result, indent=2) + '\n')
    with output.with_suffix('.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        result['pid'] = process.pid
        status.write_text(json.dumps(result, indent=2) + '\n')
        try:
            result['exit_code'] = process.wait(timeout=args.timeout)
            result['status'] = 'PASS' if result['exit_code'] == 0 else 'FAIL'
        except subprocess.TimeoutExpired:
            import os
            import signal
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            result['status'] = 'TIMEOUT'
            result['exit_code'] = process.returncode
    result['finished_utc'] = datetime.now(timezone.utc).isoformat()
    status.write_text(json.dumps(result, indent=2) + '\n')
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
