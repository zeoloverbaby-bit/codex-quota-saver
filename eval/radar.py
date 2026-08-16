"""AB 评测雷达图生成：A 臂 = 100 基准圆，B 臂 = 实测得分多边形

用法：把实测的六维 r_geo 填进 main() 的两个列表后运行：
    python radar.py
输出 radar_main.png（全任务）与 radar_t1.png .. radar_t4.png（分层，选做）。

依赖：matplotlib、numpy
"""
import matplotlib.pyplot as plt
import numpy as np

LABELS = ["额度经济性", "测试通过率", "返工轮数", "完成时间", "人工干预", "范围控制"]


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
    # —— 填实测数据：全部 run 的六维几何平均 r_geo × 100（顺序与 LABELS 一致）——
    radar([], "三层架构 vs 老方法 · 全任务", "radar_main.png",
          n_note="T1-3 各2任务/T4 1任务")
    # 分层雷达（选做）：每级一张
    for i in range(1, 5):
        radar([], f"T{i} 级", f"radar_t{i}.png", n_note="2任务")


if __name__ == "__main__":
    main()
