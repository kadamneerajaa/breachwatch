"""
BreachWatch - EDGAR ingestion (v1)

Pulls Form 8-K / 8-K/A filings that report Item 1.05 (Material Cybersecurity
Incidents) for a list of tickers, saves each raw filing document to disk,
and appends one metadata record per filing to a JSONL file.

Output (local for now; a later step loads it into Snowflake):
    data/raw/<TICKER>/<accession>.htm
    data/raw/filings_metadata.jsonl

Usage:
    export SEC_USER_AGENT="Your Name your.email@northeastern.edu"
    python ingestion/edgar_ingest.py --tickers VFC MSFT HPE UNH LDI

Notes:
    - SEC requires a User-Agent with contact info and limits traffic to
      ~10 requests/second. This script stays well under that.
    - Re-running is safe: filings already in the metadata file are skipped.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

import requests

RULE_EFFECTIVE_DATE = "2023-12-18"   # Item 1.05 disclosures began here
TICKER_MAP_URL = "https://www.sec.gov/files/company_tickers.json"
SUBMISSIONS_URL = "https://data.sec.gov/submissions/{name}"
ARCHIVE_URL = "https://www.sec.gov/Archives/edgar/data/{cik}/{acc_nodash}/{doc}"

DATA_DIR = Path("data/raw")
METADATA_FILE = DATA_DIR / "filings_metadata.jsonl"
REQUEST_PAUSE_SEC = 0.15             # ~6-7 requests/sec, under SEC's limit


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
def make_session() -> requests.Session:
    user_agent = os.environ.get("SEC_USER_AGENT")
    if not user_agent:
        sys.exit('Set SEC_USER_AGENT, e.g. export SEC_USER_AGENT="Name email@x.edu"')
    session = requests.Session()
    session.headers.update({"User-Agent": user_agent,
                            "Accept-Encoding": "gzip, deflate"})
    return session


def get(session: requests.Session, url: str, retries: int = 3) -> requests.Response:
    """GET with polite pacing and simple backoff on 429/5xx."""
    for attempt in range(retries):
        time.sleep(REQUEST_PAUSE_SEC)
        resp = session.get(url, timeout=30)
        if resp.status_code == 200:
            return resp
        if resp.status_code in (429, 500, 502, 503):
            wait = 2 ** attempt
            print(f"  {resp.status_code} on {url}, retrying in {wait}s")
            time.sleep(wait)
            continue
        resp.raise_for_status()
    raise RuntimeError(f"Failed after {retries} attempts: {url}")


# --------------------------------------------------------------------------
# EDGAR lookups
# --------------------------------------------------------------------------
def load_ticker_map(session) -> dict:
    """Return {TICKER: {'cik': int, 'name': str}}."""
    raw = get(session, TICKER_MAP_URL).json()
    return {row["ticker"].upper(): {"cik": int(row["cik_str"]), "name": row["title"]}
            for row in raw.values()}


def columns_to_rows(block: dict) -> list[dict]:
    """EDGAR returns filings as parallel arrays; turn them into row dicts."""
    keys = list(block.keys())
    return [dict(zip(keys, values)) for values in zip(*block.values())]


def fetch_all_filings(session, cik: int) -> list[dict]:
    """Recent filings plus any older overflow pages."""
    sub = get(session, SUBMISSIONS_URL.format(name=f"CIK{cik:010d}.json")).json()
    rows = columns_to_rows(sub["filings"]["recent"])
    for extra in sub["filings"].get("files", []):
        # Overflow pages hold older filings; skip ones that end before the rule.
        if extra.get("filingTo", "9999") < RULE_EFFECTIVE_DATE:
            continue
        page = get(session, SUBMISSIONS_URL.format(name=extra["name"])).json()
        rows.extend(columns_to_rows(page))
    return rows


def is_cyber_8k(row: dict, items_wanted: set[str], since: str) -> bool:
    if row.get("form") not in ("8-K", "8-K/A"):
        return False
    if row.get("filingDate", "") < since:
        return False
    items = {i.strip() for i in (row.get("items") or "").split(",")}
    return bool(items & items_wanted)


# --------------------------------------------------------------------------
# Persistence
# --------------------------------------------------------------------------
def already_ingested() -> set[str]:
    if not METADATA_FILE.exists():
        return set()
    with METADATA_FILE.open() as f:
        return {json.loads(line)["accession_number"] for line in f if line.strip()}


def save_filing(session, ticker: str, company: dict, row: dict) -> dict:
    acc = row["accessionNumber"]
    url = ARCHIVE_URL.format(cik=company["cik"],
                             acc_nodash=acc.replace("-", ""),
                             doc=row["primaryDocument"])
    html = get(session, url).text

    out_dir = DATA_DIR / ticker
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{acc}.htm"
    out_path.write_text(html, encoding="utf-8")

    return {
        "accession_number": acc,
        "ticker": ticker,
        "cik": company["cik"],
        "company_name": company["name"],
        "form_type": row["form"],
        "items": row.get("items"),
        "filing_date": row["filingDate"],
        "acceptance_datetime": row.get("acceptanceDateTime"),
        "report_date": row.get("reportDate"),   # "date of earliest event reported"
        "source_url": url,
        "local_path": str(out_path),
        "ingested_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Ingest cyber 8-Ks from EDGAR")
    parser.add_argument("--tickers", nargs="+", required=True)
    parser.add_argument("--items", nargs="+", default=["1.05"],
                        help="8-K items to keep (default: 1.05)")
    parser.add_argument("--since", default=RULE_EFFECTIVE_DATE)
    args = parser.parse_args()

    session = make_session()
    ticker_map = load_ticker_map(session)
    seen = already_ingested()
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    new_count = 0
    with METADATA_FILE.open("a") as meta_out:
        for ticker in (t.upper() for t in args.tickers):
            company = ticker_map.get(ticker)
            if not company:
                print(f"[{ticker}] not found in SEC ticker list, skipping")
                continue

            rows = fetch_all_filings(session, company["cik"])
            matches = [r for r in rows if is_cyber_8k(r, set(args.items), args.since)]
            print(f"[{ticker}] {company['name']}: {len(matches)} matching filing(s)")

            for row in matches:
                if row["accessionNumber"] in seen:
                    print(f"  {row['accessionNumber']} already ingested")
                    continue
                record = save_filing(session, ticker, company, row)
                meta_out.write(json.dumps(record) + "\n")
                seen.add(record["accession_number"])
                new_count += 1
                print(f"  saved {record['accession_number']} "
                      f"({record['form_type']}, filed {record['filing_date']})")

    print(f"\nDone. {new_count} new filing(s) written to {DATA_DIR}/")


if __name__ == "__main__":
    main()
