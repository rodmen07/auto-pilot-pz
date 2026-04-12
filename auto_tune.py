import itertools
import json
import os
import re
import shutil
import subprocess
import sys
from typing import Any

# Configurable paths
ROOT = os.path.abspath(os.path.dirname(__file__))
# All tuneable policy constants live in AutoPilot_Constants.lua (single source of truth).
CONSTANTS_FILE = os.path.join(ROOT, '42', 'media', 'lua', 'client', 'AutoPilot_Constants.lua')
AUTOMATE_SCRIPT = os.path.join(ROOT, 'automate.py')

BACKUP_CONSTANTS = CONSTANTS_FILE + '.bak'

# Parameter grid
THIRST_RANGE = [0.12, 0.16, 0.20, 0.24]
HUNGER_RANGE = [0.12, 0.16, 0.20, 0.24]
FLEE_MOODLE_RANGE = [1, 2, 3]

RESULT_FILE = os.path.join(ROOT, 'auto_tune_results.json')

# Patterns target AutoPilot_Constants.lua where the canonical values live.
pattern_thirst = re.compile(r'^(AutoPilot_Constants\.THIRST_THRESHOLD\s*=\s*)([0-9.]+)')
pattern_hunger = re.compile(r'^(AutoPilot_Constants\.HUNGER_THRESHOLD\s*=\s*)([0-9.]+)')
pattern_flee   = re.compile(r'^(AutoPilot_Constants\.FLEE_MOODLE_LIMIT\s*=\s*)(\d+)')


def backup_files():
    shutil.copyfile(CONSTANTS_FILE, BACKUP_CONSTANTS)


def restore_files():
    if not os.path.exists(BACKUP_CONSTANTS):
        raise FileNotFoundError("Backup file missing, cannot restore constants")
    shutil.copyfile(BACKUP_CONSTANTS, CONSTANTS_FILE)


def write_needs(thirst: float, hunger: float) -> None:
    text: list[str] = []
    with open(CONSTANTS_FILE, 'r', encoding='utf-8') as f:
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
    with open(CONSTANTS_FILE, 'w', encoding='utf-8') as f:
        f.writelines(text)


def write_threat(flee: int) -> None:
    text: list[str] = []
    with open(CONSTANTS_FILE, 'r', encoding='utf-8') as f:
        for line in f:
            m = pattern_flee.match(line)
            if m:
                text.append(f"{m.group(1)}{flee}\n")
            else:
                text.append(line)
    with open(CONSTANTS_FILE, 'w', encoding='utf-8') as f:
        f.writelines(text)


def run_automate(runs: int, timeout: int) -> bool:
    try:
        subprocess.run([sys.executable, AUTOMATE_SCRIPT, '--runs', str(runs), '--timeout', str(timeout)], cwd=ROOT, check=True)
        return True
    except subprocess.CalledProcessError:
        return False


def load_summary() -> dict[str, Any] | None:
    summary_path = os.path.join(ROOT, 'auto_pilot_runs_summary.json')
    if not os.path.exists(summary_path):
        return None
    with open(summary_path, 'r', encoding='utf-8') as f:
        return json.load(f)


def load_tune_results() -> list[dict[str, Any]]:
    if not os.path.exists(RESULT_FILE):
        return []
    with open(RESULT_FILE, 'r', encoding='utf-8') as f:
        data = json.load(f)
        return data.get('all', [])


def init_best_from_results(all_results: list[dict[str, Any]]) -> dict[str, Any]:
    best: dict[str, Any] = {'score': -1, 'params': None, 'result': None}
    for entry in all_results:
        score = entry.get('score')
        if score is None:
            continue
        if score > best['score']:
            best = {
                'score': score,
                'params': (
                    entry.get('thirst'),
                    entry.get('hunger'),
                    entry.get('flee_moodle_limit'),
                ),
                'result': entry,
            }
    return best


def save_tune_results(best: dict[str, Any], all_results: list[dict[str, Any]]) -> None:
    with open(RESULT_FILE, 'w', encoding='utf-8') as f:
        json.dump({'best': best, 'all': all_results}, f, indent=2)


def evaluate_summary(summary: dict[str, Any] | None) -> tuple[float, int, float, int, int]:
    if not summary or 'results' not in summary:
        return 0, 0, 0.0, 0, 0
    survival_values: list[float] = []
    deaths = 0
    ff_ratios: list[float] = []
    timeouts = 0
    for r in summary['results']:
        status = r.get('status')
        if status == 'dead':
            deaths += 1
        if status == 'timeout':
            timeouts += 1
        survival = r.get('ticks') or r.get('elapsed_seconds') or 0
        survival_values.append(float(survival))
        ff_ratios.append(float(r.get('ff_active_ratio') or 0.0))
    mean = sum(survival_values) / len(survival_values) if survival_values else 0
    ff_active_ratio_mean = sum(ff_ratios) / len(ff_ratios) if ff_ratios else 0.0
    return mean, deaths, ff_active_ratio_mean, timeouts, len(summary['results'])


def main():
    backup_files()
    all_results = load_tune_results() or []
    best = init_best_from_results(all_results)
    done_params = {(entry['thirst'], entry['hunger'], entry['flee_moodle_limit']) for entry in all_results}

    try:
        for thirst, hunger, flee in itertools.product(THIRST_RANGE, HUNGER_RANGE, FLEE_MOODLE_RANGE):
            if (thirst, hunger, flee) in done_params:
                print(f"Skipping already tested thirst={thirst}, hunger={hunger}, flee_moodle={flee}")
                continue
            print(f"Testing thirst={thirst}, hunger={hunger}, flee_moodle={flee}")
            write_needs(thirst, hunger)
            write_threat(flee)

            ok = run_automate(runs=3, timeout=600)
            if not ok:
                print("automate.py exited non-zero; marking tuple as incomplete.")
                entry: dict[str, Any] = {
                    'thirst': thirst,
                    'hunger': hunger,
                    'flee_moodle_limit': flee,
                    'score': None,
                    'incomplete': True,
                    'failure': 'automate_nonzero_exit',
                }
                all_results.append(entry)
                done_params.add((thirst, hunger, flee))
                save_tune_results(best, all_results)
                continue

            summary = load_summary()
            if not summary:
                print("No summary generated for this run.")
                entry: dict[str, Any] = {
                    'thirst': thirst,
                    'hunger': hunger,
                    'flee_moodle_limit': flee,
                    'score': None,
                    'incomplete': True,
                    'failure': 'missing_summary',
                }
                all_results.append(entry)
                done_params.add((thirst, hunger, flee))
                save_tune_results(best, all_results)
                continue

            mean_ticks, deaths, ff_active_ratio_mean, timeouts, total_runs = evaluate_summary(summary)
            timeout_ratio = (timeouts / total_runs) if total_runs else 1.0
            incomplete = timeouts > 0
            score = mean_ticks - 50 * deaths - 100 * timeouts
            print(
                "Summary: "
                f"mean_ticks={mean_ticks}, deaths={deaths}, "
                f"timeouts={timeouts}/{total_runs}, "
                f"ff_active_ratio_mean={ff_active_ratio_mean:.2f}, score={score}"
            )

            entry: dict[str, Any] = {
                'thirst': thirst,
                'hunger': hunger,
                'flee_moodle_limit': flee,
                'mean_ticks': mean_ticks,
                'deaths': deaths,
                'timeouts': timeouts,
                'timeout_ratio': timeout_ratio,
                'ff_active_ratio_mean': ff_active_ratio_mean,
                'score': score,
                'incomplete': incomplete,
                'summary': summary,
            }
            all_results.append(entry)
            done_params.add((thirst, hunger, flee))

            if not incomplete and score > best['score']:
                best.update({'score': score, 'params': (thirst, hunger, flee), 'result': entry})

            save_tune_results(best, all_results)

    finally:
        restore_files()

    print("Auto-tune complete. Best:", best)


if __name__ == '__main__':
    main()
