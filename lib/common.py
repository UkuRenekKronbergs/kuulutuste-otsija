"""Ühised utiliidid kuulutuste otsijale.

Kasutame curl_cffi, et jäljendada päris Chrome'i TLS-fingerprint'i - see läheb
Cloudflare bot-check'ist läbi ilma headless brauserita. BeautifulSoup on HTML
parsimiseks stabiilsem kui regex.
"""
from __future__ import annotations

import json
import os
import re
import statistics
from datetime import datetime
from pathlib import Path
from typing import Any

from curl_cffi import requests


USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


def fetch(url: str, *, impersonate: str = "chrome120", timeout: int = 30) -> str | None:
    """Lae URL-i sisu. impersonate='chrome120' annab Chrome TLS-fingerprint'i.

    Tagastab body stringina või None kui ei õnnestunud.
    """
    try:
        r = requests.get(
            url,
            impersonate=impersonate,
            timeout=timeout,
            headers={
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "et-EE,et;q=0.9,en;q=0.8",
            },
        )
        if r.status_code != 200:
            return None
        return r.text
    except Exception:
        return None


# ---- Price parsing ----

_NEGOTIABLE_RE = re.compile(r"kokkuleppe|l.br..k|tasuta|free|vahetus", re.IGNORECASE)
_PRICE_EXTRACT_RE = re.compile(r"\d[\d\s\u00A0.,]*\d|\d")
_US_THOUSANDS_RE = re.compile(r"^\d{1,3}(,\d{3})+(\.\d+)?$")
_EU_THOUSANDS_RE = re.compile(r"^\d{1,3}(\.\d{3})+(,\d+)?$")
_EU_DECIMAL_RE = re.compile(r"^\d+,\d+$")
_DOT_THREE_RE = re.compile(r"^\d+\.\d{3}$")


def parse_price(text: str | None) -> float | None:
    """Parsi hind stringist. Toetab formate: '5000€', '1 234,50 €', '1.234,50', '5.000'."""
    if not text:
        return None
    clean = re.sub(r"<[^>]+>", " ", text)
    clean = re.sub(r"&[a-zA-Z]+;", " ", clean)
    if _NEGOTIABLE_RE.search(clean):
        return None
    if not re.search(r"\d", clean):
        return None
    m = _PRICE_EXTRACT_RE.search(clean)
    if not m:
        return None
    n = re.sub(r"[\s\u00A0]", "", m.group())
    if _US_THOUSANDS_RE.match(n):
        n = n.replace(",", "")
    elif _EU_THOUSANDS_RE.match(n):
        n = n.replace(".", "").replace(",", ".")
    elif _EU_DECIMAL_RE.match(n):
        n = n.replace(",", ".")
    elif _DOT_THREE_RE.match(n):
        # "5.000" → 5000 (Eesti kuulutustes on punkt tuhandete eraldaja)
        n = n.replace(".", "")
    try:
        price = float(n)
        return price if price > 0 else None
    except ValueError:
        return None


# ---- HTML helpers ----

_INLINE_TAGS_RE = re.compile(
    r"</?(?:strong|b|em|i|span|u|mark|font)(?:\s[^>]*)?>", re.IGNORECASE
)


def remove_html_tags(text: str | None) -> str:
    """Eemalda HTML-tagid. Inline-tagid (strong, font jne) eemaldatakse ilma tühikuta,
    et "tool<font>ipad</font>jad" jääks "toolipadjad" (mitte "tool ipad jad")."""
    if not text:
        return ""
    t = _INLINE_TAGS_RE.sub("", text)
    t = re.sub(r"<[^>]+>", " ", t)
    # HTML-entities
    import html as html_lib
    t = html_lib.unescape(t)
    return re.sub(r"\s+", " ", t).strip()


# ---- Keyword matching ----

_EE_WORD_CHARS = r"a-z0-9\u00e4\u00f6\u00fc\u00f5"


def matches_keyword(title: str, keyword: str) -> bool:
    """Kontrolli, kas märksõna esineb pealkirjas terve fraasina (sõnapiiridega).

    Fraaside vahel võib olla ükskõik milline tühik/punktuatsioon, aga terve sõna peab
    kattuma (nt "ipad" EI sobitu "ipadiga" sisse).
    """
    if not title:
        return False
    words = [re.escape(w) for w in keyword.lower().split() if w]
    if not words:
        return False
    phrase = r"[\s\-_,./]+".join(words)
    pattern = rf"(^|[^{_EE_WORD_CHARS}]){phrase}([^{_EE_WORD_CHARS}]|$)"
    return bool(re.search(pattern, title.lower()))


# ---- Median ----

def median_price(prices: list[float]) -> float | None:
    valid = sorted(p for p in prices if p > 0)
    if not valid:
        return None
    return statistics.median(valid)


# ---- State ----

def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"seen": {}, "last_run": None}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return {"seen": data.get("seen", {}), "last_run": data.get("last_run")}
    except Exception:
        return {"seen": {}, "last_run": None}


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    state_out = {
        "last_run": datetime.now().astimezone().isoformat(timespec="seconds"),
        "seen": state["seen"],
    }
    path.write_text(
        json.dumps(state_out, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )


# ---- Listing ID extraction ----

def listing_id_from_url(url: str) -> str | None:
    if not url:
        return None
    m = re.search(r"(\d{4,})", url)
    return m.group(1) if m else url
