"""
BreachWatch - discover companies that filed cyber-incident 8-Ks.

Uses EDGAR full-text search to find every 8-K / 8-K/A mentioning "Item 1.05"
since the rule took effect, maps the companies to tickers, and prints the
tickers on one line so they can be fed straight into edgar_ingest.py.

Full-text search over-matches (e.g. 8.01 filings that say "not under Item
1.05"); that's fine, because edgar_ingest.py only keeps filings whose
official items field contains 1.05.

Usage:
    export SEC_USER_AGENT="Your Name your.email@northeastern.edu"
    python3 ingestion/edgar_ingest.py --tickers $(python3 ingestion/discover_tickers.py)
"""

import os
import sys
import time
from datetime import date

import requests

SEARCH_URL = "https://efts.sec.gov/LATEST/search-index"
TICKER_MAP_URL = "https://www.sec.gov/files/company_tickers.json"
START_DATE = "2023-12-18"
PAGE_SIZE = 100
MAX_PAGES = 20


def log(msg):
    print(msg, file=sys.stderr)   # stdout stays clean: tickers only


def main():
    ua = os.environ.get("SEC_USER_AGENT")
    if not ua:
        sys.exit('Set SEC_USER_AGENT first, e.g. export SEC_USER_AGENT="Name email@x.edu"')
    s = requests.Session()
    s.headers.update({"User-Agent": ua})

    ciks = set()
    for page in range(MAX_PAGES):
        params = {
            "q": '"Item 1.05"',
            "forms": "8-K,8-K/A",
            "dateRange": "custom",
            "startdt": START_DATE,
            "enddt": date.today().isoformat(),
            "from": page * PAGE_SIZE,
        }
        time.sleep(0.2)
        resp = s.get(SEARCH_URL, params=params, timeout=30)
        resp.raise_for_status()
        hits = resp.json().get("hits", {}).get("hits", [])
        if not hits:
            break
        for h in hits:
            for c in h.get("_source", {}).get("ciks", []):
                ciks.add(int(c))
        log(f"page {page + 1}: {len(hits)} hits, {len(ciks)} unique companies so far")
        if len(hits) < PAGE_SIZE:
            break

    time.sleep(0.2)
    raw = s.get(TICKER_MAP_URL, timeout=30).json()
    cik_to_ticker = {}
    for row in raw.values():
        cik_to_ticker.setdefault(int(row["cik_str"]), row["ticker"].upper())

    tickers = sorted({cik_to_ticker[c] for c in ciks if c in cik_to_ticker})
    unmapped = len(ciks) - len(tickers)
    log(f"{len(tickers)} tickers found ({unmapped} companies had no current ticker)")
    print(" ".join(tickers))


if __name__ == "__main__":
    main()
