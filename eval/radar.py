"""AB 评测雷达图生成：results.csv（score.py 输出）→ PNG
用法: python radar.py --csv results.csv
无数据时打印用法说明并以退出码 1 结束（不再需要改源码填列表）。
"""
import argparse
import csv
import sys

import matplotlib.pyplot as plt
import numpy as np

LABELS = ["额度经济性", "测试通过率", "返工轮数", "完成时间", "人工干预", "范围控制"]
COLS = ["quota_econ", "pass_rate", "rework", "wall_time", "interventions", "scope"]


def radar(scores_b, title, filename, n_note):
    """scores_b: B 臂六维得分（r_geo×100，已截断 200）"""
    baseline = [100] * len(LABELS)
    angles = np.linspace(0, 2 * np.pi, len(LABELS), endpoint=False).tolist()
    angles += angles[:1]

    fig, ax = plt.subplots(figsize=(7, 7), subplot_kw=dict(polar=True))
    ax.plot(angles, baseline + baseline[:1], "k--", linewidth=1, label="老方法（基准圆=100）")
    ax.fill(angles, scores_b + scores_b[:1], alpha=0.25, color="#ff5c5c", label="新方法（三层架构）")
    ax.plot(angles, scores_b + scores_b[:1], "-", linewidth=2, color="#ff5c5c")
    ax.set_xticks(angles[:-1])
    ax.set_xticklabels(LABELS, fontsize=11)
    ax.set_ylim(0, 200)
    ax.set_yticks([50, 100, 150, 200])
    ax.set_yticklabels(["50", "100", "150", "200"], fontsize=8)
    ax.set_title(title, pad=20, fontsize=14)
    ax.legend(loc="upper right", bbox_to_anchor=(1.3, 1.1), fontsize=10)
    ax.text(0, -0.25, f"n={n_note} | 分数=r_geo×100，截断200 | 越出圆=优于老方法",
            ha="center", fontsize=8, transform=ax.transAxes)
    plt.tight_layout()
    plt.savefig(filename, dpi=150)
    plt.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    args = ap.parse_args()
    try:
        with open(args.csv, encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
    except FileNotFoundError:
        print(f"找不到 {args.csv}：请先运行 collect.py → score.py 生成 results.csv")
        sys.exit(1)
    if not rows:
        print("results.csv 为空：先跑完评测并用 collect.py/score.py 填数")
        sys.exit(1)
    for r in rows:
        scores = [min(float(r[c]) * 100, 200) for c in COLS]
        radar(scores, f"三层架构 vs 老方法 · {r['tier']}", f"radar_{r['tier']}.png",
              n_note=f"n={r['n']}")


if __name__ == "__main__":
    main()
