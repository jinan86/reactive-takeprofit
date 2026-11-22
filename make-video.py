#!/usr/bin/env python3
"""TakeProfit demo video — slide-based, 1280x720, ~100-140s.
Renders PNG slides with PIL and concatenates them with ffmpeg + silent audio.
Fill in the TX_* constants from demo-run.log before running.
"""
import os
import subprocess
import textwrap

from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 720
OUT = os.path.dirname(os.path.abspath(__file__))
SLIDES_DIR = os.path.join(OUT, "video-slides")
os.makedirs(SLIDES_DIR, exist_ok=True)

# --- fill these from demo-run.log (short hashes shown on slides) ---
TX_ORDER = "0xd9327b33…e06b209"      # createOrder #2
TX_BELOW = "0x93102d4b…cb4b52"      # setPrice $1500
TX_ABOVE = "0xb39200fd…2796f8"      # setPrice $2100
TX_REACT = "0xa3f5c2cf…441196b"      # Lasna react() tx
TX_CALLBACK = "0x7e86a502…bc4b7b"      # Base Sepolia callback tx
TX_AGAIN = "0x4c6eb2e9…89fb9d"      # setPrice $2200

BG = (13, 17, 23)
CARD = (22, 27, 34)
ACCENT = (88, 166, 255)
GREEN = (63, 185, 80)
RED = (248, 81, 73)
TEXT = (230, 237, 243)
MUTED = (139, 148, 158)

FONT_BIG = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def font(size, bold=False):
    return ImageFont.truetype(FONT_BIG if bold else FONT_REG, size)


def slide(idx, title, lines, accent=ACCENT, seconds=16):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([60, 60, W - 60, H - 60], radius=24, fill=CARD)
    d.rectangle([60, 60, W - 60, 72], fill=accent)
    d.text((100, 110), title, font=font(44), fill=TEXT)
    y = 200
    for line in lines:
        for chunk in textwrap.wrap(line, width=62):
            d.text((100, y), chunk, font=font(30), fill=TEXT if not chunk.startswith("  ") else MUTED)
            y += 46
        y += 14
    d.text((100, H - 110), "TakeProfit  ·  Reactive Omni Buildathon — Set It and Forget It  ·  testnet",
           font=font(20), fill=MUTED)
    path = os.path.join(SLIDES_DIR, f"slide{idx:02d}.png")
    img.save(path)
    return path, seconds


def main():
    slides = [
        slide(1, "TakeProfit — set it and forget it",
              ["Set once: \u201csell 10 tTOKEN when the price hits $2,000\u201d.",
               "A Reactive contract watches the price and executes the sale.",
               "No bot. No server. No keeper. No AI — just a price threshold."],
              seconds=14),
        slide(2, "1 · Create the order",
              ["User calls OrderVault.createOrder(10 tTOKEN, target $2,000).",
               "10 tTOKEN lock in the vault. Order #2 is live on Base Sepolia.",
               f"tx {TX_ORDER}"],
              seconds=14),
        slide(3, "2 · Price $1,500 — below target",
              ["Oracle publishes $1,500. Reactive sees it… and does NOTHING.",
               "reactCount rises, actedCount stays 0. Order stays active.",
               "No execution, no funds moved. Fail closed, by design.",
               f"tx {TX_BELOW}"],
              seconds=16),
        slide(4, "3 · Price $2,100 — target hit",
              ["Oracle publishes $2,100 ≥ $2,000 target.",
               "TakeProfitReactive on Lasna fires and requests a callback.",
               f"tx {TX_ABOVE}"],
              seconds=14),
        slide(5, "4 · Callback executes the sale",
              ["OrderExecutor re-checks: order active, unexecuted,",
               "price still ≥ target — then settles.",
               "Payee receives exactly 10 × $2,100 = 21,000 tUSD.",
               f"react {TX_REACT}",
               f"callback {TX_CALLBACK}"],
              accent=GREEN, seconds=18),
        slide(6, "5 · No double pay",
              ["Price $2,200 again: a second callback is requested,",
               "but the executor refuses — the order already executed.",
               "Payee balance stays exactly 21,000 tUSD.",
               f"tx {TX_AGAIN}"],
              accent=GREEN, seconds=14),
        slide(7, "What TakeProfit is NOT",
              ["Not GuardianLepas: no lending, no health factor, no liquidation.",
               "Not Tripwire: no allowlist / denylist.",
               "Not Sentinel: no AI in the loop — deterministic price rule only.",
               "Repo: github.com/jinan86/reactive-takeprofit"],
              seconds=16),
    ]
    total = sum(s for _, s in slides)
    print(f"slides: {len(slides)}, total ~{total}s")
    # Build ffmpeg concat input
    concat = os.path.join(SLIDES_DIR, "concat.txt")
    with open(concat, "w") as f:
        for path, secs in slides:
            f.write(f"file '{path}'\nduration {secs}\n")
        f.write(f"file '{slides[-1][0]}'\n")
    out = os.path.join(OUT, "demo-video.mp4")
    subprocess.run([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat,
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
        "-map", "0:v", "-map", "1:a", "-t", str(total),
        "-vf", "format=yuv420p", "-c:v", "libx264", "-r", "30",
        "-c:a", "aac", "-shortest", out,
    ], check=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
