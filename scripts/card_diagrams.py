"""Draws the transformer diagrams used on flashcards (docs/card-images/*.png).
Run: python3 scripts/card_diagrams.py"""
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

OUT = os.path.join(os.path.dirname(__file__), "..", "docs", "card-images")
INK, BLUE, PINK, GREEN, GRAY = "#111", "#dbe8ff", "#ffd9e0", "#d9f2df", "#eeeeee"
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 12})


def box(ax, x, y, w, h, text, fc):
    ax.add_patch(FancyBboxPatch((x - w / 2, y - h / 2), w, h, boxstyle="round,pad=0.02,rounding_size=0.08",
                                fc=fc, ec=INK, lw=1.6))
    ax.text(x, y, text, ha="center", va="center", fontsize=12)


def arrow(ax, x0, y0, x1, y1):
    ax.add_patch(FancyArrowPatch((x0, y0), (x1, y1), arrowstyle="-|>", mutation_scale=14, lw=1.6, color=INK))


def plus(ax, x, y):
    ax.text(x, y, "+", ha="center", va="center", fontsize=14, weight="bold",
            bbox=dict(boxstyle="circle,pad=0.12", fc="white", ec=INK, lw=1.4))


def decoder_only():
    fig, ax = plt.subplots(figsize=(5.2, 8.4))
    ax.set_xlim(0, 6); ax.set_ylim(0, 11.6); ax.axis("off")
    box(ax, 3, 0.6, 3.2, 0.7, "token ids  t  (length T)", GRAY)
    box(ax, 3, 1.8, 3.2, 0.7, "Embed  →  T × d", BLUE)
    arrow(ax, 3, 0.95, 3, 1.45)
    # one block, repeated L times
    ax.add_patch(FancyBboxPatch((0.7, 2.55), 4.6, 5.85, boxstyle="round,pad=0.02,rounding_size=0.15",
                                fc="white", ec=INK, lw=1.4, ls="--"))
    ax.text(5.15, 8.1, "× L", ha="right", fontsize=13, weight="bold")
    box(ax, 3, 3.3, 2.6, 0.55, "RMSNorm", GRAY)
    box(ax, 3, 4.3, 2.9, 0.7, "Masked MHSA (+RoPE)", PINK)
    plus(ax, 3, 5.2)
    box(ax, 3, 6.1, 2.6, 0.55, "RMSNorm", GRAY)
    box(ax, 3, 7.1, 2.6, 0.7, "SwiGLU FFN", GREEN)
    plus(ax, 3, 8.0)
    # main path
    arrow(ax, 3, 2.15, 3, 3.02); arrow(ax, 3, 3.58, 3, 3.95); arrow(ax, 3, 4.65, 3, 5.0)
    arrow(ax, 3, 5.4, 3, 5.82); arrow(ax, 3, 6.38, 3, 6.75); arrow(ax, 3, 7.45, 3, 7.8)
    # residual skips: branch before each norm, rejoin at the +
    for y0, y1 in [(2.75, 5.2), (5.6, 8.0)]:
        ax.plot([3, 1.2, 1.2], [y0, y0, y1], color=INK, lw=1.4)
        arrow(ax, 1.2, y1, 2.78, y1)
    box(ax, 3, 9.0, 2.6, 0.55, "RMSNorm", GRAY)
    box(ax, 3, 10.0, 3.2, 0.7, "Unembed  →  T × vocab", BLUE)
    box(ax, 3, 11.0, 2.6, 0.55, "softmax", GRAY)
    arrow(ax, 3, 8.2, 3, 8.72); arrow(ax, 3, 9.28, 3, 9.65); arrow(ax, 3, 10.35, 3, 10.72)
    fig.savefig(os.path.join(OUT, "decoder-only.png"), dpi=200, bbox_inches="tight", facecolor="white")


def causal_mask():
    T = 6
    m = np.tril(np.ones((T, T)))
    fig, ax = plt.subplots(figsize=(5, 4.6))
    ax.imshow(m, cmap=matplotlib.colors.ListedColormap(["#f3f3f3", "#6aa9ff"]), vmin=0, vmax=1)
    for i in range(T):
        for j in range(T):
            ax.text(j, i, "✓" if m[i, j] else "−∞", ha="center", va="center",
                    color="white" if m[i, j] else "#999", fontsize=12, weight="bold")
    words = ["The", "cat", "sat", "on", "the", "mat"]
    ax.set_xticks(range(T), words); ax.set_yticks(range(T), words)
    ax.set_xlabel("key (attended to)"); ax.set_ylabel("query (position)")
    ax.xaxis.set_label_position("top"); ax.xaxis.tick_top()
    ax.set_title("Each token sees itself and the past;\nfuture scores are set to −∞ before softmax", fontsize=11, pad=34)
    fig.savefig(os.path.join(OUT, "causal-mask.png"), dpi=200, bbox_inches="tight", facecolor="white")


def rope():
    fig, ax = plt.subplots(figsize=(5, 5))
    ax.set_aspect("equal"); ax.axhline(0, color="#ccc"); ax.axvline(0, color="#ccc")
    v = np.array([1.0, 0.25]); theta = 0.45
    cols = plt.cm.viridis(np.linspace(0, 0.85, 5))
    for i in range(5):
        a = i * theta
        r = np.array([[np.cos(a), -np.sin(a)], [np.sin(a), np.cos(a)]]) @ v
        ax.annotate("", r, (0, 0), arrowprops=dict(arrowstyle="-|>", color=cols[i], lw=2.2))
        ax.text(*(r * 1.12), f"pos {i}", color=cols[i], ha="center", va="center", fontsize=11)
    ax.set_xlim(-1.3, 1.4); ax.set_ylim(-0.4, 1.4); ax.axis("off")
    ax.set_title("RoPE: each (q, k) dimension pair is rotated\nby angle i·θ_k, so q·k depends on the offset", fontsize=11)
    fig.savefig(os.path.join(OUT, "rope.png"), dpi=200, bbox_inches="tight", facecolor="white")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    decoder_only(); causal_mask(); rope()
    print("wrote", sorted(os.listdir(OUT)))
