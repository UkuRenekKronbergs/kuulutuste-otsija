"""Scraperid kõigi saitide jaoks. Iga scraper tagastab list[Listing]."""
from __future__ import annotations

import re
from dataclasses import dataclass, asdict
from typing import Any
from urllib.parse import quote

from bs4 import BeautifulSoup, Tag

from .common import (
    fetch,
    matches_keyword,
    parse_price,
    remove_html_tags,
)


@dataclass
class Listing:
    id: str
    title: str
    price: float
    url: str
    site: str
    location: str = ""
    date: str = ""
    keyword: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


# ---- soov.ee ----

def scrape_soov(keyword: str, config: dict[str, Any]) -> list[Listing]:
    url = f"https://soov.ee/keyword-{quote(keyword)}/order-price/order_way-asc/listings.html"
    html = fetch(url, impersonate="chrome120")
    if not html:
        print(f"  soov.ee: ei saanud vastust")
        return []
    results: list[Listing] = []
    # Iga kuulutus: <div class="item-list category-view category-id-XXX" id="LYYYYYY">...
    pattern = re.compile(
        r'<div class="item-list category-view[^"]*"\s+id="L(\d+)">(.*?)<!--/\.item-list-->',
        re.DOTALL,
    )
    for m in pattern.finditer(html):
        lid = m.group(1)
        block = m.group(2)
        t_m = re.search(r'<h4 class="add-title">(.*?)</h4>', block, re.DOTALL)
        u_m = re.search(r'<a\s+href="(https://soov\.ee/[^"]*/details\.html)"', block)
        p_m = re.search(r'<h4 class="item-price[^"]*">([^<]+)</h4>', block)
        loc_m = re.search(
            r'<span class="item-location">.*?<i[^>]*></i>\s*(?:&nbsp;)?\s*([^<]+?)\s*</span>',
            block,
            re.DOTALL,
        )
        d_m = re.search(r'<span class="date" title="([^"]+)">', block)
        if not (t_m and u_m and p_m):
            continue
        raw_title = re.sub(r'<span class="thin">[^<]*</span>', "", t_m.group(1))
        title = remove_html_tags(raw_title)
        price = parse_price(p_m.group(1))
        if price is None:
            continue
        if not matches_keyword(title, keyword):
            continue
        results.append(Listing(
            id=f"soov:{lid}",
            title=title,
            price=price,
            url=u_m.group(1),
            site="soov.ee",
            location=remove_html_tags(loc_m.group(1)) if loc_m else "",
            date=d_m.group(1) if d_m else "",
            keyword=keyword,
        ))
    return results


# ---- osta.ee ----

def scrape_osta(keyword: str, config: dict[str, Any]) -> list[Listing]:
    url = (
        f"https://www.osta.ee/?fuseaction=search.search"
        f"&q%5Bq%5D={quote(keyword)}&q%5Bcat%5D=1000&q%5Bshow_items%5D=1"
    )
    html = fetch(url, impersonate="chrome120")
    if not html:
        print(f"  osta.ee: ei saanud vastust")
        return []
    if "Just a moment" in html or "Vabandame, meie s" in html:
        print(f"  osta.ee: anti-bot blokeeris")
        return []
    results: list[Listing] = []
    # Iga kuulutus on <figure ... data-analytics-ecommerce-target="item" data-title="..." data-price="..." ...>
    fig_re = re.compile(r'<figure[^>]+data-analytics-ecommerce-target="item"[^>]*>')
    for m in fig_re.finditer(html):
        block_end = min(m.start() + 3000, len(html))
        block = html[m.start():block_end]
        t_m = re.search(r'data-title="([^"]*)"', m.group())
        p_m = re.search(r'data-price="([^"]*)"', m.group())
        l_m = re.search(r'href="(/[^"]*-(\d{7,})\.html)"', block)
        if not (t_m and p_m and l_m):
            continue
        title = remove_html_tags(t_m.group(1))
        if not matches_keyword(title, keyword):
            continue
        price = parse_price(p_m.group(1))
        if price is None:
            continue
        d_m = re.search(
            r'offer-thumb__metadata--item[^>]*>\s*<span>\s*([^<]+?)\s*</span>',
            block,
            re.DOTALL,
        )
        results.append(Listing(
            id=f"osta:{l_m.group(2)}",
            title=title,
            price=price,
            url=f"https://www.osta.ee{l_m.group(1)}",
            site="osta.ee",
            date=d_m.group(1).strip() if d_m else "",
            keyword=keyword,
        ))
    return results


# ---- kuldnebors.ee ----

def scrape_kuldnebors(keyword: str, config: dict[str, Any]) -> list[Listing]:
    url = (
        f"https://www.kuldnebors.ee/search/search.mec"
        f"?search_O_string={quote(keyword)}&pob_action=search"
    )
    html = fetch(url, impersonate="chrome120")
    if not html:
        print(f"  kuldnebors.ee: ei saanud vastust")
        return []
    if re.search(r"Vabandame, meie s.steem", html):
        print(f"  kuldnebors.ee: anti-bot blokeeris")
        return []
    results: list[Listing] = []
    # Iga kuulutus: <div class="row kb-object" data-post-row="ID">...</div>
    pattern = re.compile(
        r'<div class="row kb-object" data-post-row="(\d+)">(.*?)'
        r'(?=<div class="row kb-object"|<div class="kb-pagination|<footer|</body>)',
        re.DOTALL,
    )
    for m in pattern.finditer(html):
        lid = m.group(1)
        block = m.group(2)
        # Välista "ostan" kuulutused
        if re.search(r"pob_deal_type=O[^a-zA-Z]", block):
            continue
        t_m = re.search(
            r'<h4 class="kb-object__heading[^"]*"><a[^>]+href="([^"]+)"[^>]*>([^<]+)</a>',
            block,
            re.DOTALL,
        )
        if not t_m:
            continue
        rel_url = remove_html_tags(t_m.group(1))
        title = remove_html_tags(t_m.group(2))
        if not matches_keyword(title, keyword):
            continue
        # Viimane <span class="fgN"> on praegune hind
        price_text: str | None = None
        for pm in re.finditer(r'<span class="fg\d+">([^<]+?)</span>', block):
            price_text = pm.group(1)
        if not price_text:
            pm2 = re.search(
                r'<span class="kb-object__price">.*?(\d[\d\s.,]*)\s*€',
                block,
                re.DOTALL,
            )
            if pm2:
                price_text = pm2.group(1)
        if not price_text:
            continue
        price = parse_price(price_text)
        if price is None:
            continue
        loc_m = re.search(
            r'<div class="kb-object__location[^"]*">.*?</span>([^<]+)</div>',
            block,
            re.DOTALL,
        )
        d_m = re.search(
            r'<div class="kb-object__date">\s*sisestatud\s+([\d.]+)\s*</div>',
            block,
        )
        href = rel_url if rel_url.startswith(("http://", "https://")) else f"https://www.kuldnebors.ee{rel_url}"
        results.append(Listing(
            id=f"kuldnebors:{lid}",
            title=title,
            price=price,
            url=href,
            site="kuldnebors.ee",
            location=remove_html_tags(loc_m.group(1)) if loc_m else "",
            date=d_m.group(1) if d_m else "",
            keyword=keyword,
        ))
    return results


# ---- okidoki.ee ----

def scrape_okidoki(keyword: str, config: dict[str, Any]) -> list[Listing]:
    """Okidoki.ee kasutab Cloudflare bot-check'i. curl_cffi Chrome-impersonation peaks
    sellest läbi saama, aga mõnikord on challenge siiski aktiivne - siis tagastame [].
    """
    url = f"https://www.okidoki.ee/buy/all/?query={quote(keyword)}&sort=price_asc"
    html = fetch(url, impersonate="chrome120")
    if not html:
        print(f"  okidoki.ee: ei saanud vastust")
        return []
    if "Just a moment" in html or "challenge-platform" in html:
        print(f"  okidoki.ee: Cloudflare blokeeris")
        return []
    results: list[Listing] = []
    soup = BeautifulSoup(html, "html.parser")
    # Okidoki kuulutuste link: /buy/.../DIGITS/ (ID lõpus)
    # Tüüpiline kaart: <div class="offer-row"> ... <h3><a href="/buy/.../ID/">Title</a></h3> ... hind
    for a in soup.select('a[href^="/buy/"]'):
        href = a.get("href", "")
        m = re.search(r"/buy/[^/]+/.*?/(\d+)/?$", href)
        if not m:
            m = re.search(r"/(\d+)/?$", href)
        if not m:
            continue
        lid = m.group(1)
        title = a.get_text(strip=True)
        if not title or len(title) < 3:
            # Võib-olla kasutatakse atribuuti
            title = a.get("title", "")
        if not title:
            continue
        if not matches_keyword(title, keyword):
            continue
        # Otsi hind lähedal (parent kaardis)
        parent = a
        price: float | None = None
        for _ in range(5):
            parent = parent.parent
            if parent is None:
                break
            price_el = parent.find(string=re.compile(r"\d+\s*€"))
            if price_el:
                price = parse_price(str(price_el))
                if price is not None:
                    break
        if price is None:
            continue
        full_url = href if href.startswith("http") else f"https://www.okidoki.ee{href}"
        # Dedup sama ID-ga
        if any(r.id == f"okidoki:{lid}" for r in results):
            continue
        results.append(Listing(
            id=f"okidoki:{lid}",
            title=title,
            price=price,
            url=full_url,
            site="okidoki.ee",
            keyword=keyword,
        ))
    return results


# ---- yaga.ee ----

def scrape_yaga(keyword: str, config: dict[str, Any]) -> list[Listing]:
    """Yaga.ee on Next.js SPA. Tulemused kuvatakse ainult hinna + brändiga
    (toote pealkirja HTML-is pole). Sobitame brändi/shop nime suhtes.
    Kuna yaga on peamiselt moemaja, elektroonikat sealt harva leiab.
    """
    url = f"https://www.yaga.ee/search?q={quote(keyword)}"
    html = fetch(url, impersonate="chrome120", timeout=45)
    if not html:
        print(f"  yaga.ee: ei saanud vastust")
        return []
    results: list[Listing] = []
    # <a class="no-style" href="/SHOP/toode/ID?rank=N">...<h5 class="price">33&nbsp;€</h5>...<div class="brand-container"><h5 class="details">BRAND</h5></div></a>
    pattern = re.compile(
        r'<a class="no-style" href="(/[^/]+/toode/([a-z0-9]+)\?rank=\d+)"[^>]*>(.*?)</a>',
        re.DOTALL,
    )
    for m in pattern.finditer(html):
        rel = m.group(1)
        lid = m.group(2)
        block = m.group(3)
        p_m = re.search(r'<h5 class="price">([^<]+)</h5>', block)
        if not p_m:
            continue
        price = parse_price(p_m.group(1))
        if price is None:
            continue
        b_m = re.search(
            r'<div class="brand-container">.*?<h5 class="details">([^<]+)</h5>',
            block,
            re.DOTALL,
        )
        brand = remove_html_tags(b_m.group(1)) if b_m else ""
        shop_m = re.search(r"/([^/]+)/toode/", rel)
        shop = shop_m.group(1) if shop_m else ""
        pseudo_title = " ".join(x for x in (brand, shop) if x) or lid
        if not matches_keyword(pseudo_title, keyword):
            continue
        results.append(Listing(
            id=f"yaga:{lid}",
            title=pseudo_title,
            price=price,
            url=f"https://www.yaga.ee{rel}",
            site="yaga.ee",
            keyword=keyword,
        ))
    return results


# ---- Dispatcher ----

SCRAPERS = {
    "soov": scrape_soov,
    "osta": scrape_osta,
    "kuldnebors": scrape_kuldnebors,
    "okidoki": scrape_okidoki,
    "yaga": scrape_yaga,
}


def scrape_all(keyword: str, config: dict[str, Any]) -> list[Listing]:
    all_results: list[Listing] = []
    sites = config.get("sites", {})
    for name, scraper in SCRAPERS.items():
        if not sites.get(name, False):
            continue
        try:
            all_results.extend(scraper(keyword, config))
        except Exception as e:
            print(f"  {name}: viga - {e}")
    return all_results
