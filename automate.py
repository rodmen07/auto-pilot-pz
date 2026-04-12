import argparse
import atexit
import json
import os
import shutil
import subprocess
import sys
import time
import uuid

try:
    import benchmark as _benchmark_mod
    _BENCHMARK_AVAILABLE = True
except ImportError:
    _BENCHMARK_AVAILABLE = False

# Adjust these paths for your install
# Use Steam protocol run to ensure Steam-managed game startup works on this machine.
PZ_EXE = r"steam://rungameid/108600"
# Fallback to local path if needed (adjust to your install directory if not using ware)
PZ_EXE_FALLBACK = r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\ProjectZomboid64.exe"
ROOT = os.path.abspath(os.path.dirname(__file__))
SAVE_DIR = os.path.expanduser(r"~\Zomboid\Saves\Survivor")
TEMPLATE_SAVE = os.path.expanduser(r"~\Zomboid\Saves\template_save")
TELEMETRY_DIR = os.path.expanduser(r"~\Zomboid\Lua")
LOCK_FILE = os.path.join(ROOT, ".automate.lock")
LOCK_TOKEN = None

RUN_LOG = os.path.join(TELEMETRY_DIR, "auto_pilot_run.log")
RUN_END = os.path.join(TELEMETRY_DIR, "auto_pilot_run_end.json")


def _pid_is_alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def acquire_lock():
    global LOCK_TOKEN
    if os.path.exists(LOCK_FILE):
        try:
            with open(LOCK_FILE, "r", encoding="utf-8") as f:
                lock = json.load(f)
            pid = int(lock.get("pid", 0))
            if pid > 0 and _pid_is_alive(pid):
                raise RuntimeError(
                    f"automate.py already running (pid={pid}). "
                    "Stop other run before starting a new one."
                )
        except (ValueError, json.JSONDecodeError):
            pass

    LOCK_TOKEN = uuid.uuid4().hex
    lock = {
        "pid": os.getpid(),
        "started_at": time.time(),
        "token": LOCK_TOKEN,
    }
    with open(LOCK_FILE, "w", encoding="utf-8") as f:
        json.dump(lock, f, indent=2)


def release_lock():
    if not os.path.exists(LOCK_FILE):
        return

    try:
        with open(LOCK_FILE, "r", encoding="utf-8") as f:
            lock = json.load(f)
        if lock.get("pid") == os.getpid() and lock.get("token") == LOCK_TOKEN:
            os.remove(LOCK_FILE)
    except (OSError, ValueError, json.JSONDecodeError):
        pass
    if os.path.exists(LOCK_FILE):
        try:
            os.remove(LOCK_FILE)
        except OSError:
            pass


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
            try:
                with open(RUN_END, "r", encoding="utf-8") as f:
                    return json.load(f)
            except (json.JSONDecodeError, OSError):
                # Marker may still be in the middle of a write; retry next poll.
                pass
        time.sleep(poll)
    return None


def write_run_end_marker(status, reason, ticks=0):
    os.makedirs(TELEMETRY_DIR, exist_ok=True)
    marker = {
        "status": status,
        "reason": reason,
        "ticks": ticks,
        "timestamp": time.time(),
    }
    with open(RUN_END, "w", encoding="utf-8") as f:
        json.dump(marker, f, indent=2)


def parse_run_log(run_log_path):
    if not os.path.exists(run_log_path):
        return {
            "lines": 0,
            "last": "",
            "ff_active_lines": 0,
            "ff_normal_lines": 0,
            "ff_unknown_lines": 0,
            "ff_active_ratio": 0.0,
            "max_run_tick": 0,
            "action_counts": {},
        }

    def parse_kv_line(line):
        parsed = {}
        for part in line.split(","):
            if "=" not in part:
                continue
            key, value = part.split("=", 1)
            parsed[key.strip()] = value.strip()
        return parsed

    lines = []
    ff_active_lines = 0
    ff_normal_lines = 0
    ff_unknown_lines = 0
    max_run_tick = 0
    action_counts = {}
    with open(run_log_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.read().strip().splitlines()
    for line in lines:
        kv = parse_kv_line(line)
        ff_state = kv.get("ff")
        if ff_state == "active":
            ff_active_lines += 1
        elif ff_state == "normal":
            ff_normal_lines += 1
        else:
            ff_unknown_lines += 1
        run_tick_val = kv.get("run_tick")
        if run_tick_val is not None:
            try:
                tick = int(float(run_tick_val))
                max_run_tick = max(max_run_tick, tick)
            except ValueError:
                pass
        action = kv.get("action")
        if action:
            action_counts[action] = action_counts.get(action, 0) + 1

    known_ff_lines = ff_active_lines + ff_normal_lines
    ff_active_ratio = ff_active_lines / known_ff_lines if known_ff_lines else 0.0

    return {
        "lines": len(lines),
        "last": lines[-1] if lines else "",
        "ff_active_lines": ff_active_lines,
        "ff_normal_lines": ff_normal_lines,
        "ff_unknown_lines": ff_unknown_lines,
        "ff_active_ratio": ff_active_ratio,
        "max_run_tick": max_run_tick,
        "action_counts": action_counts,
    }


def kill_pz(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()

    # Ensure Project Zomboid process is terminated for Steam URL mode
    for exe_name in ["ProjectZomboid64.exe", "ProjectZomboid.exe"]:
        try:
            subprocess.run(["taskkill", "/F", "/IM", exe_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def _run_benchmark(log_path, end_status, run_id):
    """Run offline benchmark analysis on the completed run log.

    Returns a dict with key benchmark metrics, or an empty dict if the
    benchmark module is not available or the log file is missing.
    """
    if not _BENCHMARK_AVAILABLE:
        return {}
    try:
        entries = _benchmark_mod.parse_telemetry(log_path)
        if not entries:
            return {}
        result = _benchmark_mod.score_run(entries, end_status=end_status)
        out_path = os.path.join(ROOT, f"auto_pilot_benchmark_{run_id}.json")
        _benchmark_mod.write_benchmark(result, out_path)
        print(f"Benchmark: ticks={result.total_ticks}, score={result.score:.0f}, "
              f"combat_rate={result.combat_rate:.2f}, injury_rate={result.injury_rate:.2f}")
        return {
            "total_ticks":     result.total_ticks,
            "score":           result.score,
            "combat_rate":     result.combat_rate,
            "injury_rate":     result.injury_rate,
            "exercise_rate":   result.exercise_rate,
            "hunger_pressure": result.hunger_pressure,
            "thirst_pressure": result.thirst_pressure,
            "action_counts":   result.action_counts,
        }
    except Exception as exc:
        print(f"Benchmark failed (non-fatal): {exc}")
        return {}


def run_once(timeout=900, run_id=None):
    run_id = run_id or uuid.uuid4().hex
    print("Preparing save...")
    copy_save()

    if os.path.exists(RUN_LOG):
        os.remove(RUN_LOG)
    if os.path.exists(RUN_END):
        os.remove(RUN_END)

    # Create empty run log so external users can rely on file presence shortly after run start.
    os.makedirs(TELEMETRY_DIR, exist_ok=True)
    with open(RUN_LOG, "w", encoding="utf-8"):
        pass

    print(f"Starting Project Zomboid via Steam URL... run_id={run_id}")
    run_started_at = time.time()
    launch_mode = "steam_url"
    try:
        proc = subprocess.Popen(["cmd", "/C", "start", "", PZ_EXE], shell=False)
    except Exception as exc:
        print("Steam URL launch failed, trying fallback executable:", exc)
        launch_mode = "fallback_exe"
        proc = None
        if os.path.exists(PZ_EXE_FALLBACK):
            proc = subprocess.Popen([PZ_EXE_FALLBACK], shell=False)
        else:
            print("Fallback path does not exist:", PZ_EXE_FALLBACK)

    print("Process PID:", proc.pid if proc else None)
    try:
        res = wait_for_run_end(timeout)
        log_summary = parse_run_log(RUN_LOG)
        if res is None:
            print("Timeout waiting for run_end; killing process")
            kill_pz(proc)
            elapsed_seconds = time.time() - run_started_at
            timed_out_ticks = log_summary.get("max_run_tick", 0)
            write_run_end_marker("timeout", "timeout", ticks=timed_out_ticks)
            run_result = {
                "run_id": run_id,
                "started_at": run_started_at,
                "launch_mode": launch_mode,
                "status": "timeout",
                "reason": "timeout",
                "ticks": timed_out_ticks,
                "elapsed_seconds": elapsed_seconds,
                "log_lines": log_summary["lines"],
                "log_last": log_summary["last"],
                "ff_active_lines": log_summary["ff_active_lines"],
                "ff_normal_lines": log_summary["ff_normal_lines"],
                "ff_unknown_lines": log_summary["ff_unknown_lines"],
                "ff_active_ratio": log_summary["ff_active_ratio"],
                "action_counts": log_summary.get("action_counts", {}),
            }
            run_result["benchmark"] = _run_benchmark(RUN_LOG, "timeout", run_id)
            return run_result

        print("Run ended:", res)
        elapsed_seconds = time.time() - run_started_at
        kill_pz(proc)
        end_status = res.get("status", "unknown")
        run_result = {
            "run_id": run_id,
            "started_at": run_started_at,
            "launch_mode": launch_mode,
            "status": end_status,
            "reason": res.get("reason"),
            "ticks": res.get("ticks"),
            "elapsed_seconds": elapsed_seconds,
            "log_lines": log_summary["lines"],
            "log_last": log_summary["last"],
            "ff_active_lines": log_summary["ff_active_lines"],
            "ff_normal_lines": log_summary["ff_normal_lines"],
            "ff_unknown_lines": log_summary["ff_unknown_lines"],
            "ff_active_ratio": log_summary["ff_active_ratio"],
            "action_counts": log_summary.get("action_counts", {}),
        }
        run_result["benchmark"] = _run_benchmark(RUN_LOG, end_status, run_id)
        return run_result
    finally:
        kill_pz(proc)


def main():
    parser = argparse.ArgumentParser(description="AutoPilot endurance test runner")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    acquire_lock()
    atexit.register(release_lock)

    results = []
    for i in range(args.runs):
        print(f"=== Run {i+1}/{args.runs} ===")
        run_id = uuid.uuid4().hex
        r = run_once(timeout=args.timeout, run_id=run_id)
        results.append(r)
        out = os.path.join(ROOT, f"auto_pilot_run_{i+1}.json")
        with open(out, "w", encoding="utf-8") as f:
            json.dump(r, f, indent=2)
        print("Saved run result to", out)
        time.sleep(5)

    summary = {
        "generated_at": time.time(),
        "runs": len(results),
        "results": results,
    }
    with open(os.path.join(ROOT, "auto_pilot_runs_summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    print("Done. Summary written.")


if __name__ == "__main__":
    main()
