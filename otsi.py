#!/usr/bin/env python3
"""Kuulutuste otsija - peaskript (Python versioon, sobib Linux'ile / Claude Schedule'ile).

Kasutamine:
    python otsi.py                          # kõik märksõnad config.json-ist
    python otsi.py --keyword "iphone 13"    # üks märksõna
    python otsi.py --show-all               # näita ka varem nähtud häid hindu
    python otsi.py --no-state               # ära uuenda state seen.json-i
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime
from pathlib import Path

from lib.common import load_state, median_price, save_state
from lib.scrapers import scrape_all


SCRIPT_DIR = Path(__file__).resolve().parent


def fmt_duration(seconds: float) -> str:
    m = int(seconds // 60)
    s = int(seconds % 60)
    return f"{m:02d}:{s:02d}"


def main() -> int:
    p = argparse.ArgumentParser(description="Kuulutuste otsija")
    p.add_argument("--config", default=str(SCRIPT_DIR / "config.json"))
    p.add_argument("--keyword")
    p.add_argument("--show-all", action="store_true")
    p.add_argument("--no-state", action="store_true")
    args = p.parse_args()

    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    state_path = SCRIPT_DIR / "state" / "seen.json"
    state = load_state(state_path)

    if args.keyword:
        searches = [{"keyword": args.keyword, "min_price": 0, "max_price": 999999}]
    else:
        searches = config.get("searches", [])

    blocklist = [w.lower() for w in config.get("blocklist", [])]

    run_start = time.monotonic()
    now = datetime.now().astimezone()
    print(f"=== Kuulutuste otsija | {now:%Y-%m-%d %H:%M} ===")

    all_results: list[dict] = []

    for search in searches:
        kw = search["keyword"]
        max_price = float(search.get("max_price", 999999))
        min_price = float(search.get("min_price", 0))
        max_str = "pole" if max_price >= 999999 else f"{max_price}€"
        print()
        print(f"[{kw}] (min {min_price}€, max {max_str})")

        listings = scrape_all(kw, config)
        if not listings:
            print("  (tulemusi ei leitud)")
            time.sleep(config.get("request_delay_ms", 1500) / 1000.0)
            continue

        # Blocklist (substring-match sest Eesti keeles liitsõnad kirjutatakse kokku)
        filtered = []
        blocked = 0
        for lst in listings:
            title_lower = lst.title.lower()
            if any(w in title_lower for w in blocklist):
                blocked += 1
            else:
                filtered.append(lst)

        # Mediaan ainult "tõsistest" (min_price..max_price vahemikus)
        serious_prices = [l.price for l in filtered if min_price <= l.price <= max_price]
        med = median_price(serious_prices)

        good_deals = []
        min_samples = config.get("min_samples_for_median", 4)
        threshold = config.get("median_threshold", 0.85)
        for lst in filtered:
            if lst.price < min_price or lst.price > max_price:
                continue
            if med is not None and len(serious_prices) >= min_samples:
                if lst.price > med * threshold:
                    continue
            pct = round((1 - lst.price / med) * 100) if med else 0
            good_deals.append({
                **lst.to_dict(),
                "median": med,
                "pct_under_med": pct,
                "first_seen": now.isoformat(timespec="seconds"),
            })

        if args.no_state:
            new = good_deals
        else:
            seen = state["seen"]
            new = [d for d in good_deals if d["id"] not in seen]

        med_str = f"{round(med)}" if med else "?"
        print(
            f"  leitud: {len(listings)} (filtr. aksessuaare: {blocked}) | "
            f"mediaan: {med_str}€ | head hinnad: {len(good_deals)} | uued: {len(new)}"
        )

        target = good_deals if args.show_all else new
        all_results.extend(target)

        for d in new:
            pct = d["pct_under_med"]
            pct_str = f"-{pct}%" if pct > 0 else ""
            print(f"    {d['price']:>7.0f}€ {pct_str:<4} [{d['site']}] {d['title']}")
            print(f"             {d['url']}")

        for d in good_deals:
            state["seen"][d["id"]] = now.strftime("%Y-%m-%d")

        time.sleep(config.get("request_delay_ms", 1500) / 1000.0)

    # Salvesta tulemused
    date_str = now.strftime("%Y-%m-%d")
    results_dir = SCRIPT_DIR / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    results_path = results_dir / f"{date_str}.json"

    existing = []
    if results_path.exists() and not args.show_all:
        try:
            old = json.loads(results_path.read_text(encoding="utf-8"))
            existing = old.get("listings", [])
        except Exception:
            pass
    combined = existing + all_results

    results_path.write_text(
        json.dumps(
            {
                "run_at": now.isoformat(timespec="seconds"),
                "total": len(combined),
                "listings": combined,
            },
            indent=2,
            ensure_ascii=False,
            default=str,
        ),
        encoding="utf-8",
    )

    if not args.no_state:
        save_state(state_path, state)

    elapsed = time.monotonic() - run_start
    mode = "head hinda" if args.show_all else "uut head hinda"
    print()
    print(
        f"=== Valmis. Leidsin {len(all_results)} {mode}, "
        f"aeg {fmt_duration(elapsed)}. Salvestatud: {results_path} ==="
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
