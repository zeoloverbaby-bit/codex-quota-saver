# tests/test_eval.py —— eval 管道单测（collect → score）
import csv
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "eval"))
import collect  # noqa: E402
import score  # noqa: E402

SAMPLE_JSONL = [
    {"type": "turn_context", "payload": {"model": "gpt-5.6-luna"}},
    {"type": "event_msg", "payload": {"type": "token_count", "total_token_usage": 1000,
        "input_tokens": 900, "output_tokens": 100, "reasoning_output_tokens": 10, "cached_input_tokens": 890}},
    {"type": "event_msg", "payload": {"type": "token_count", "total_token_usage": 1500,
        "input_tokens": 400, "output_tokens": 100, "reasoning_output_tokens": 5, "cached_input_tokens": 380}},
    {"type": "turn_context", "payload": {"model": "gpt-5.6-sol"}},
    {"type": "event_msg", "payload": {"type": "token_count", "total_token_usage": 2000}},
]


def test_collect_delta_per_turn_attributed_to_nearest_model(tmp_path):
    f = tmp_path / "s.jsonl"
    f.write_text("\n".join(json.dumps(e) for e in SAMPLE_JSONL) + "\n", encoding="utf-8")
    out = collect.extract(collect.parse_session(str(f)))
    assert len(out) == 3
    assert out[0]["model"] == "gpt-5.6-luna" and out[0]["delta_total_tokens"] == 1000
    assert out[1]["delta_total_tokens"] == 500
    assert out[2]["model"] == "gpt-5.6-sol" and out[2]["delta_total_tokens"] == 500


LEDGER_CSV = """run_id,tier,task,arm,order,date,main_model,main_effort,sub_model,sub_effort,main_tok_in,main_tok_out,sub_tok_in,sub_tok_out,web_chars_in,web_chars_out,quota_units,pass_focused,pass_affected,rework_rounds,wall_minutes,interventions,out_of_scope_files,notes
r1,T1,T1-a,A,1,2026-08-16,gpt-5.6-sol,high,,,0,0,0,0,0,0,,2,2,1,30,1,0,
r2,T1,T1-a,B,2,2026-08-16,gpt-5.6-luna,max,,,0,0,0,0,0,0,,2,2,1,40,1,0,
"""


def test_score_computes_quota_units_and_ratio(tmp_path):
    ledger = tmp_path / "l.csv"
    ledger.write_text(LEDGER_CSV, encoding="utf-8")
    raw = tmp_path / "r.jsonl"
    raw.write_text(json.dumps({"run_id": "r1", "model": "gpt-5.6-sol", "delta_total_tokens": 1000}) + "\n" +
                   json.dumps({"run_id": "r2", "model": "gpt-5.6-luna", "delta_total_tokens": 2000}) + "\n",
                   encoding="utf-8")
    out = tmp_path / "results.csv"
    score.run(str(ledger), str(raw), str(out), coeff=0.05)
    rows = list(csv.DictReader(out.open(encoding="utf-8")))
    assert len(rows) == 1  # 每个 tier 一行
    r = rows[0]
    assert r["tier"] == "T1"
    # A 臂 quota = 1000 sol ×1 = 1000；B 臂 = 2000 luna ×0.05 = 100 → r = A/B = 10
    assert abs(float(r["quota_econ"]) - 10.0) < 1e-6
