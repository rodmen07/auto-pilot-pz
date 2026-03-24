import itertools
import json
import os
import re
import shutil
import subprocess
import sys
import time

# Configurable paths
ROOT = os.path.abspath(os.path.dirname(__file__))
NEEDS_FILE = os.path.join(ROOT, 'media', 'lua', 'client', 'AutoPilot_Needs.lua')
THREAT_FILE = os.path.join(ROOT, 'media', 'lua', 'client', 'AutoPilot_Threat.lua')
AUTOMATE_SCRIPT = os.path.join(ROOT, 'automate.py')

BACKUP_NEEDS = NEEDS_FILE + '.bak'
BACKUP_THREAT = THREAT_FILE + '.bak'

# Parameter grid
THIRST_RANGE = [0.12, 0.16, 0.20, 0.24]
HUNGER_RANGE = [0.12, 0.16, 0.20, 0.24]
FLEE_MOODLE_RANGE = [1, 2, 3]

RESULT_FILE = os.path.join(ROOT, 'auto_tune_results.json')

pattern_thirst = re.compile(r'^(\s*local\s+THIRST_STAT_THRESHOLD\s*=\s*)([0-9.]+)')
pattern_hunger = re.compile(r'^(\s*local\s+HUNGER_STAT_THRESHOLD\s*=\s*)([0-9.]+)')
pattern_flee = re.compile(r'^(\s*local\s+FLEE_MOODLE_LIMIT\s*=\s*)(\d+)')


def backup_files():
    if not os.path.exists(BACKUP_NEEDS):
        shutil.copyfile(NEEDS_FILE, BACKUP_NEEDS)
    if not os.path.exists(BACKUP_THREAT):
        shutil.copyfile(THREAT_FILE, BACKUP_THREAT)


def restore_files():
    if os.path.exists(BACKUP_NEEDS):
        shutil.copyfile(BACKUP_NEEDS, NEEDS_FILE)
    if os.path.exists(BACKUP_THREAT):
        shutil.copyfile(BACKUP_THREAT, THREAT_FILE)


def write_needs(thirst, hunger):
    text = []
    with open(NEEDS_FILE, 'r', encoding='utf-8') as f:
        for line in f:
            m = pattern_thirst.match(line)
            if m:
                text.append(f"{m.group(1)}{thirst:.2f}\n")
                continue
            m = pattern_hunger.match(line)
            if m:
                text.append(f"{m.group(1)}{hunger:.2f}\n")
                continue
            text.append(line)
    with open(NEEDS_FILE, 'w', encoding='utf-8') as f:
        f.writelines(text)


def write_threat(flee):
    text = []
    with open(THREAT_FILE, 'r', encoding='utf-8') as f:
        for line in f:
            m = pattern_flee.match(line)
            if m:
                text.append(f"{m.group(1)}{flee}\n")
            else:
                text.append(line)
    with open(THREAT_FILE, 'w', encoding='utf-8') as f:
        f.writelines(text)


def run_automate(runs, timeout):
    proc = subprocess.run([sys.executable, AUTOMATE_SCRIPT, '--runs', str(runs), '--timeout', str(timeout)], cwd=ROOT)
    return proc.returncode == 0


def load_summary():
    summary_path = os.path.join(ROOT, 'auto_pilot_runs_summary.json')
    if not os.path.exists(summary_path):
        return None
    with open(summary_path, 'r') as f:
        return json.load(f)


def evaluate_summary(summary):
    if not summary or 'results' not in summary:
        return 0, 0
    ticks = []
    deaths = 0
    for r in summary['results']:
        if r.get('status') == 'dead':
            deaths += 1
        val = r.get('ticks') or 0
        ticks.append(val)
    mean = sum(ticks) / len(ticks) if ticks else 0
    return mean, deaths


def main():
    backup_files()
    best = {'score': -1, 'params': None, 'result': None}
    all_results = []

    try:
        for thirst, hunger, flee in itertools.product(THIRST_RANGE, HUNGER_RANGE, FLEE_MOODLE_RANGE):
            print(f"Testing thirst={thirst}, hunger={hunger}, flee_moodle={flee}")
            write_needs(thirst, hunger)
            write_threat(flee)

            ok = run_automate(runs=3, timeout=600)
            summary = load_summary()
            if not summary:
                print("No summary generated for this run.")
                continue
            mean_ticks, deaths = evaluate_summary(summary)
            score = mean_ticks - 50 * deaths
            print(f"Summary: mean_ticks={mean_ticks}, deaths={deaths}, score={score}")

            entry = {
                'thirst': thirst,
                'hunger': hunger,
                'flee_moodle_limit': flee,
                'mean_ticks': mean_ticks,
                'deaths': deaths,
                'score': score,
                'summary': summary,
            }
            all_results.append(entry)

            if score > best['score']:
                best.update({'score': score, 'params': (thirst, hunger, flee), 'result': entry})

            with open(RESULT_FILE, 'w') as f:
                json.dump({'best': best, 'all': all_results}, f, indent=2)

    finally:
        restore_files()

    print("Auto-tune complete. Best:", best)


if __name__ == '__main__':
    main()
