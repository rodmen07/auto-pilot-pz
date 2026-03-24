import argparse
import json
import os
import shutil
import subprocess
import sys
import time

# Adjust these paths for your install
PZ_EXE = r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\ProjectZomboid64.exe"
SAVE_DIR = os.path.expanduser(r"~\Zomboid\Saves\Survivor")
TEMPLATE_SAVE = os.path.expanduser(r"~\Zomboid\Saves\template_save")
TELEMETRY_DIR = os.path.expanduser(r"~\Zomboid\Lua")

RUN_LOG = os.path.join(TELEMETRY_DIR, "auto_pilot_run.log")
RUN_END = os.path.join(TELEMETRY_DIR, "auto_pilot_run_end.json")


def copy_save():
    if not os.path.exists(TEMPLATE_SAVE):
        raise FileNotFoundError(f"Template save not found: {TEMPLATE_SAVE}")
    if os.path.exists(SAVE_DIR):
        shutil.rmtree(SAVE_DIR)
    shutil.copytree(TEMPLATE_SAVE, SAVE_DIR)


def wait_for_run_end(timeout=900, poll=2):
    start = time.time()
    while time.time() - start < timeout:
        if os.path.exists(RUN_END):
            with open(RUN_END, "r") as f:
                return json.load(f)
        time.sleep(poll)
    return None


def parse_run_log(run_log_path):
    if not os.path.exists(run_log_path):
        return {}
    last = None
    lines = []
    with open(run_log_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.read().strip().splitlines()
    return {
        "lines": len(lines),
        "last": lines[-1] if lines else "",
    }


def kill_pz(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()


def run_once(timeout=900):
    print("Preparing save...")
    copy_save()

    if os.path.exists(RUN_LOG):
        os.remove(RUN_LOG)
    if os.path.exists(RUN_END):
        os.remove(RUN_END)

    print("Starting Project Zomboid...")
    proc = subprocess.Popen([PZ_EXE], shell=False)
    try:
        res = wait_for_run_end(timeout)
        if res is None:
            print("Timeout waiting for run_end; killing process")
            kill_pz(proc)
            return {"status":"timeout"}

        print("Run ended:", res)
        log_summary = parse_run_log(RUN_LOG)
        kill_pz(proc)
        return {
            "status": res.get("status", "unknown"),
            "reason": res.get("reason"),
            "ticks": res.get("ticks"),
            "log_lines": log_summary["lines"],
            "log_last": log_summary["last"],
        }
    finally:
        kill_pz(proc)


def main():
    parser = argparse.ArgumentParser(description="AutoPilot endurance test runner")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    results = []
    for i in range(args.runs):
        print(f"=== Run {i+1}/{args.runs} ===")
        r = run_once(timeout=args.timeout)
        results.append(r)
        out = os.path.join(os.getcwd(), f"auto_pilot_run_{i+1}.json")
        with open(out, "w") as f:
            json.dump(r, f, indent=2)
        print("Saved run result to", out)
        time.sleep(5)

    summary = {
        "runs": len(results),
        "results": results,
    }
    with open(os.path.join(os.getcwd(), "auto_pilot_runs_summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    print("Done. Summary written.")


if __name__ == "__main__":
    main()
