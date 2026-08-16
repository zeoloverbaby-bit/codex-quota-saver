# eval/collect.py —— session JSONL → raw_runs.jsonl
# 口径（eval/README §2.1.1 已验证）：event_msg.type=token_count 的 total_token_usage 是会话累计，
# 相邻差 = 轮级增量；归因给最近的 turn_context.model。
# 用法: python collect.py --session <path.jsonl> --run-id r1 [--out raw_runs.jsonl]
import argparse
import json


def parse_session(path: str):
    events = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def extract(events):
    rows, current_model, prev_total = [], "unknown", None
    for ev in events:
        if ev.get("type") == "turn_context":
            m = (ev.get("payload") or {}).get("model") or ev.get("model")
            if m:
                current_model = m
        elif ev.get("type") == "event_msg":
            p = ev.get("payload") or {}
            if p.get("type") == "token_count":
                total = p.get("total_token_usage")
                if total is None:
                    continue
                # 首个事件：基线 = 会话起点（0），增量即累计值本身
                delta = total if prev_total is None else max(total - prev_total, 0)
                prev_total = total
                rows.append({
                    "model": current_model,
                    "delta_total_tokens": delta,
                    "input_tokens": p.get("input_tokens"),
                    "output_tokens": p.get("output_tokens"),
                    "reasoning_output_tokens": p.get("reasoning_output_tokens"),
                    "cached_input_tokens": p.get("cached_input_tokens"),
                })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True)
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--out", default="raw_runs.jsonl")
    args = ap.parse_args()
    with open(args.out, "a", encoding="utf-8") as f:
        for r in extract(parse_session(args.session)):
            f.write(json.dumps({"run_id": args.run_id, **r}, ensure_ascii=False) + "\n")
    print(f"appended to {args.out}")


if __name__ == "__main__":
    main()
