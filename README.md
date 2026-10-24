# BreachWatch

Tracking SEC cybersecurity incident disclosures with RAG and agentic AI.
DAMG 6300 (Gen AI with LLMs in Data Engineering), Fall 2026, Group 2:
Neerajaa Kadam, Hiteshi Kawadia, Krishi Parekh.

## The problem

Since December 18, 2023, US public companies must disclose material
cybersecurity incidents on Form 8-K, Item 1.05, within four business days
of determining the incident is material. There is no simple way to check
whether companies meet that window or how their disclosures change over time.

BreachWatch collects every Item 1.05 filing from SEC EDGAR, loads it into
Snowflake, and (in progress) exposes it to an AI agent through an MCP server
so questions like "Did this company disclose on time?" are answered with
evidence from the filing text.

## Current data

- 44 filings (19 original 8-Ks plus 8-K/A amendments) from 20 companies
- Period: December 2023 to June 2026
- Source: SEC EDGAR (free, public)

## Architecture

See [`docs/BreachWatch_Architecture_and_Data_Model.pdf`](docs/BreachWatch_Architecture_and_Data_Model.pdf).

```
SEC EDGAR -> Python ingestion -> Snowflake stage -> RAW tables -> (dbt) STAGING/MARTS -> (RAG + MCP) -> AI assistant
              built               built             built          planned               planned
```

## Repository layout

| Path | What it does |
|---|---|
| `ingestion/discover_tickers.py` | Finds every company with an Item 1.05 8-K via EDGAR full-text search |
| `ingestion/edgar_ingest.py` | Downloads matching 8-K / 8-K/A filings and writes metadata (JSONL) |
| `sql/01_snowflake_setup.sql` | Creates the database, RAW/STAGING/MARTS schemas, stage, file formats, RAW tables |
| `sql/02_load_and_query.sql` | Loads staged files into RAW and runs the v1 timeliness analysis |
| `docs/` | Architecture diagram and data model |

## How to run

```bash
python3 -m pip install -r requirements.txt
export SEC_USER_AGENT="Your Name your.email@northeastern.edu"
python3 ingestion/edgar_ingest.py --tickers $(python3 ingestion/discover_tickers.py)
```

Then in Snowflake: run `sql/01_snowflake_setup.sql`, upload
`data/raw/filings_metadata.jsonl` to `@EDGAR_STAGE/metadata/` and the `.htm`
files to `@EDGAR_STAGE/docs/`, and run `sql/02_load_and_query.sql`.

## Findings so far

- All 19 original 8-Ks were filed within four business days of their
  cover-page report date, and 6 of 19 were filed on exactly day four.
- The report date is set by the company and is not necessarily the
  materiality determination date, so v1 compliance results are an upper bound.
  v2 will extract the materiality date from the filing text.
- Amendments share the original filing's report date, which lets us link an
  original 8-K and its 8-K/As into one incident.
- After SEC staff guidance in May 2024, many incidents moved to Item 8.01,
  which v1 does not yet cover.

## Status

- [x] EDGAR discovery and ingestion
- [x] Snowflake RAW layer and loading
- [x] v1 timeliness analysis in SQL
- [ ] dbt models: clean HTML, extract Item 1.05 text, build incidents
- [ ] Federal holiday calendar for business-day counts
- [ ] Embeddings and LLM extraction of materiality dates
- [ ] MCP server tools and AI assistant
- [ ] Airflow orchestration
