# eval/score.py —— ledger.csv + raw_runs.jsonl → results.csv（六维比率 + 按级几何平均）
# quota_units = Σ sol_token×1 + Σ luna_token×coeff（coeff 默认 0.05=1/20；执行前按系数复核提醒校准）
# 用法: python score.py --ledger ledger.csv --raw raw_runs.jsonl [--coeff 0.05] [--out results.csv]
import argparse
import csv
import json
import math
from collections import defaultdict

DIMS = ["quota_econ", "pass_rate", "rework", "wall_time", "interventions", "scope"]
LOW_GOOD = {"quota_econ", "rework", "wall_time", "interventions", "scope"}


def read_raw(path):
    rows = defaultdict(lambda: defaultdict(int))
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            rows[r["run_id"]][r["model"]] += r.get("delta_total_tokens", 0)
    return rows


def ratio(a, b, low_good):
    if a == b:
        return 1.0
    if low_good:
        return a / b if b > 0 else (0.0 if a > 0 else 1.0)
    return b / a if a > 0 else (0.0 if b > 0 else 1.0)


def run(ledger_path, raw_path, out_path, coeff=0.05):
    raw = read_raw(raw_path)
    tasks = defaultdict(list)  # (tier, task) -> list of {arm, quota, row}
    with open(ledger_path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            run_id = row["run_id"]
            arm = row["arm"]
            sol = raw[run_id].get("gpt-5.6-sol", 0)
            luna = raw[run_id].get("gpt-5.6-luna", 0)
            quota = sol * 1.0 + luna * coeff
            tasks[(row["tier"], row["task"])].append({"arm": arm, "quota": quota, "row": row})

    out_rows = []
    for (tier, _task), pairs in sorted(tasks.items()):
        a = next((p for p in pairs if p["arm"] == "A"), None)
        b = next((p for p in pairs if p["arm"] == "B"), None)
        if a is None or b is None:
            continue
        ra = a["row"]
        rb = b["row"]
        r = {
            "quota_econ": ratio(a["quota"], b["quota"], True),
            "pass_rate": ratio(
                int(ra["pass_focused"] or 0) + int(ra["pass_affected"] or 0),
                int(rb["pass_focused"] or 0) + int(rb["pass_affected"] or 0), False),
            "rework": ratio(int(ra["rework_rounds"] or 0), int(rb["rework_rounds"] or 0), True),
            "wall_time": ratio(int(ra["wall_minutes"] or 0), int(rb["wall_minutes"] or 0), True),
            "interventions": ratio(int(ra["interventions"] or 0), int(rb["interventions"] or 0), True),
            "scope": ratio(int(ra["out_of_scope_files"] or 0), int(rb["out_of_scope_files"] or 0), True),
        }
        out_rows.append((tier, r))

    by_tier = defaultdict(list)
    for t, r in out_rows:
        by_tier[t].append(r)

    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["tier", "n"] + DIMS)
        w.writeheader()
        for t, rs in sorted(by_tier.items()):
            geo = {}
            for d in DIMS:
                vals = [r[d] for r in rs if r[d] > 0]
                geo[d] = math.exp(sum(math.log(v) for v in vals) / len(vals)) if vals else 0.0
            w.writerow({"tier": t, "n": len(rs), **{d: round(geo[d], 4) for d in DIMS}})
    print(f"wrote {out_path}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--raw", required=True)
    ap.add_argument("--coeff", type=float, default=0.05)
    ap.add_argument("--out", default="results.csv")
    a = ap.parse_args()
    run(a.ledger, a.raw, a.out, a.coeff)
