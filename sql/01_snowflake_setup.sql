-- =====================================================================
-- BreachWatch: Snowflake setup (v1)
-- Creates the database, the three layers, a stage for uploaded files,
-- and the RAW tables that the ingestion output lands in.
--
-- Run top to bottom with "Run All" (Cmd+Shift+Enter).
-- Safe to re-run: everything uses IF NOT EXISTS.
-- Commit this file to the repo as sql/01_snowflake_setup.sql
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE BREACHWATCH_WH;

-- ---------------------------------------------------------------------
-- 1. Database and layers
--    RAW      = exactly what came from EDGAR, untouched
--    STAGING  = cleaned and typed (built by dbt later)
--    MARTS    = what the MCP server / agent queries (built by dbt later)
-- ---------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS BREACHWATCH;
CREATE SCHEMA IF NOT EXISTS BREACHWATCH.RAW;
CREATE SCHEMA IF NOT EXISTS BREACHWATCH.STAGING;
CREATE SCHEMA IF NOT EXISTS BREACHWATCH.MARTS;

USE SCHEMA BREACHWATCH.RAW;

-- ---------------------------------------------------------------------
-- 2. Internal stage: a landing folder inside Snowflake for uploaded files
--    Expected layout after upload:
--      @EDGAR_STAGE/metadata/filings_metadata.jsonl
--      @EDGAR_STAGE/docs/<TICKER>/<accession>.htm
-- ---------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS EDGAR_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Raw EDGAR files uploaded from the ingestion script';

-- ---------------------------------------------------------------------
-- 3. File formats
-- ---------------------------------------------------------------------
-- One JSON object per line (what edgar_ingest.py writes)
CREATE FILE FORMAT IF NOT EXISTS JSONL_FORMAT
  TYPE = JSON
  STRIP_OUTER_ARRAY = FALSE;

-- Read an entire HTML file as ONE text value (no splitting into rows/cols)
CREATE FILE FORMAT IF NOT EXISTS WHOLE_FILE_TEXT
  TYPE = CSV
  FIELD_DELIMITER = NONE
  RECORD_DELIMITER = NONE
  FIELD_OPTIONALLY_ENCLOSED_BY = NONE
  ESCAPE_UNENCLOSED_FIELD = NONE;

-- ---------------------------------------------------------------------
-- 4. RAW tables
-- ---------------------------------------------------------------------
-- Metadata kept as VARIANT so new fields from the script never break loads
CREATE TABLE IF NOT EXISTS FILINGS_METADATA (
    record       VARIANT,
    source_file  STRING,
    loaded_at    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- One row per filing document, full raw HTML
CREATE TABLE IF NOT EXISTS FILING_DOCUMENTS (
    accession_number  STRING,
    raw_html          STRING,
    source_file       STRING,
    loaded_at         TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =====================================================================
-- STOP HERE until files are uploaded to the stage (see instructions).
-- Then run sections 5 and 6.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 5. Load from stage
--    COPY INTO remembers which files it already loaded, so re-running
--    only picks up new files.
-- ---------------------------------------------------------------------
COPY INTO FILINGS_METADATA (record, source_file)
FROM (
    SELECT $1, METADATA$FILENAME
    FROM @EDGAR_STAGE/metadata/
)
FILE_FORMAT = (FORMAT_NAME = 'JSONL_FORMAT');

COPY INTO FILING_DOCUMENTS (accession_number, raw_html, source_file)
FROM (
    SELECT
        REGEXP_SUBSTR(METADATA$FILENAME, '[0-9]{10}-[0-9]{2}-[0-9]{6}'),
        $1,
        METADATA$FILENAME
    FROM @EDGAR_STAGE/docs/
)
FILE_FORMAT = (FORMAT_NAME = 'WHOLE_FILE_TEXT')
PATTERN = '.*\\.htm';

-- ---------------------------------------------------------------------
-- 6. Sanity checks
-- ---------------------------------------------------------------------
-- Typed view of the metadata (quick check, dbt will own this later)
SELECT
    record:accession_number::STRING  AS accession_number,
    record:ticker::STRING            AS ticker,
    record:company_name::STRING      AS company_name,
    record:form_type::STRING         AS form_type,
    record:filing_date::DATE         AS filing_date,
    record:report_date::DATE         AS report_date
FROM FILINGS_METADATA
ORDER BY filing_date;

-- Every metadata row should have a matching document (expect 0 rows)
SELECT m.record:accession_number::STRING AS missing_doc
FROM FILINGS_METADATA m
LEFT JOIN FILING_DOCUMENTS d
  ON d.accession_number = m.record:accession_number::STRING
WHERE d.accession_number IS NULL;

-- Document sizes look reasonable (not empty, not truncated)
SELECT accession_number, LENGTH(raw_html) AS html_chars
FROM FILING_DOCUMENTS
ORDER BY html_chars;
