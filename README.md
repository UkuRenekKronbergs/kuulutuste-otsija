# Kuulutuste otsija

App, mis jälgib hea hinnaga järelturu kuulutusi Eestis. Saadaval kahe variandina:

- **Python** — `otsi.py` (kiirem, töötab Linux'is, sobib Claude Schedule / GitHub Actions jaoks)
- **PowerShell** — `otsi.ps1` (originaal, Windows-spetsiifiline, kasutab Microsoft Edge'i)

## Toetatud saidid

| Sait | Töötab | Märkus |
|------|--------|--------|
| soov.ee | ✅ | lihtne HTTP, mõlemas versioonis |
| osta.ee | ✅ | curl_cffi / Edge headless |
| kuldnebors.ee | ✅ | curl_cffi / Edge headless |
| okidoki.ee | ⚠️ | Cloudflare JS challenge — vajab päris brauserit (Playwright vms) |
| yaga.ee | ⚠️ | Next.js SPA, tulemused laetakse JS-iga — enamasti moemaja, elektroonikat harva |

## Hinnaloogika

Iga otsingusõna juures määrad `min_price` ja `max_price`. Script kogub kõigilt lubatud saitidelt kokku, filtreerib välja aksessuaarid (blocklist), arvutab mediaani `[min_price, max_price]` vahemiku kuulutustest (nii ei moonuta ümbrised ega laadijad pilti) ja tähistab "heaks hinnaks" need, kus:

```
hind ∈ [min_price, max_price]  AND  hind ≤ mediaan × median_threshold
```

`state/seen.json` hoiab varem nähtud kuulutuste ID-sid, et iga käivitus näitaks ainult uusi leide.

## Python versioon (soovitav)

### Installimine

```bash
pip install -r requirements.txt
```

Sõltuvused: `curl_cffi` (Cloudflare-taluv HTTP), `beautifulsoup4`.

### Kasutamine

```bash
python otsi.py                          # kõik config.json-i märksõnad
python otsi.py --keyword "iphone 13"    # üks märksõna
python otsi.py --show-all               # ka varem nähtud head hinnad
python otsi.py --no-state               # ära uuenda seen.json-i
```

### Claude Schedule / GitHub Actions

Python versioon on disainitud remote käivitamiseks. Lihtsaim on luua trigger, mis:

1. Kloonib selle repo
2. `pip install -r requirements.txt`
3. `python otsi.py`
4. Commit `results/` ja `state/seen.json` muudatused

Näidis trigger prompt:
```
Kloonige repo ja käivitage:
  pip install -r requirements.txt
  python otsi.py

Seejärel stage'ige ja commit'ige muudatused state/ ja results/ kaustades sõnumiga
"Igapäevane otsing: N uut head hinda" ning push-ige main harule.
```

## PowerShell versioon (Windows lokaalne)

```
powershell -ExecutionPolicy Bypass -File otsi.ps1
powershell -ExecutionPolicy Bypass -File otsi.ps1 -Keyword "iphone 13"
```

PowerShelli versioon kasutab Microsoft Edge headless-režiimi osta.ee ja kuldnebors.ee jaoks. See on veidi aeglasem (~3 min vs ~5 sek Python-is), aga ei vaja Python'i installi.

Windows Task Scheduleriga igapäevaseks käivitamiseks:

```
schtasks /create /tn "Kuulutuste otsija" /sc daily /st 08:00 /tr "powershell -ExecutionPolicy Bypass -File \"C:\tee\juurde\otsi.ps1\""
```

## Konfigureerimine

Muuda [config.json](config.json). Näide:

```json
{
  "median_threshold": 0.85,
  "min_samples_for_median": 4,
  "blocklist": ["kaitse", "ümbris", "kaabel", "laadija", "klaas"],
  "sites": {
    "soov": true,
    "osta": true,
    "kuldnebors": true,
    "okidoki": false,
    "yaga": false
  },
  "searches": [
    { "keyword": "iphone 13", "min_price": 100, "max_price": 400 },
    { "keyword": "macbook",   "min_price": 200, "max_price": 700 }
  ]
}
```

## Struktuur

```
.
├── otsi.py               # Python peaskript
├── otsi.ps1              # PowerShell peaskript
├── config.json           # märksõnad, hinnavahemikud, blocklist
├── requirements.txt      # Python sõltuvused
├── warmup.ps1            # Edge Cloudflare warmup (PS jaoks)
├── lib/
│   ├── common.py         # HTTP, parsing, state (Python)
│   ├── scrapers.py       # 5 saidi scraperid (Python)
│   ├── common.ps1        # sama (PowerShell)
│   └── scrapers.ps1      # sama (PowerShell)
├── state/seen.json       # varem nähtud ID-d (dedup)
└── results/YYYY-MM-DD.json  # päevased leiud
```

## Litsents

MIT.
