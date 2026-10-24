-- =====================================================================
-- BreachWatch: load staged EDGAR files into RAW and run first analysis
-- Prerequisite: 01_snowflake_setup.sql has run, and files are uploaded to
--   @EDGAR_STAGE/metadata/  (filings_metadata.jsonl)
--   @EDGAR_STAGE/docs/      (one .htm per filing)
-- =====================================================================
USE SCHEMA BREACHWATCH.RAW;

-- Full reload (safe to re-run)
TRUNCATE TABLE FILINGS_METADATA;
TRUNCATE TABLE FILING_DOCUMENTS;

COPY INTO FILINGS_METADATA (record, source_file)
FROM (SELECT $1, METADATA$FILENAME FROM @EDGAR_STAGE/metadata/)
FILE_FORMAT = (FORMAT_NAME = 'JSONL_FORMAT')
FORCE = TRUE;

COPY INTO FILING_DOCUMENTS (accession_number, raw_html, source_file)
FROM (
  SELECT REGEXP_SUBSTR(METADATA$FILENAME, '[0-9]{10}-[0-9]{2}-[0-9]{6}'),
         $1,
         METADATA$FILENAME
  FROM @EDGAR_STAGE/docs/
)
FILE_FORMAT = (FORMAT_NAME = 'WHOLE_FILE_TEXT')
PATTERN = '.*\\.htm'
FORCE = TRUE;

-- Load check: expect matching counts
SELECT
  (SELECT COUNT(*) FROM FILINGS_METADATA) AS metadata_rows,
  (SELECT COUNT(*) FROM FILING_DOCUMENTS) AS document_rows,
  (SELECT COUNT(DISTINCT record:ticker::STRING) FROM FILINGS_METADATA) AS companies;

-- All filings, typed
SELECT
  record:ticker::STRING           AS ticker,
  record:company_name::STRING     AS company,
  record:form_type::STRING        AS form,
  record:filing_date::DATE        AS filing_date,
  record:report_date::DATE        AS report_date,
  record:accession_number::STRING AS accession_number
FROM FILINGS_METADATA
ORDER BY ticker, filing_date;

-- Timeliness v1: business days from cover-page report date to filing date,
-- original 8-Ks only. Skips weekends; federal holidays not yet handled.
-- NOTE: report_date is company-reported and is not necessarily the
-- materiality determination date (v2 extracts that from filing text).
WITH originals AS (
  SELECT record:ticker::STRING        AS ticker,
         record:company_name::STRING  AS company,
         record:report_date::DATE     AS report_date,
         record:filing_date::DATE     AS filing_date
  FROM FILINGS_METADATA
  WHERE record:form_type::STRING = '8-K'
),
counted AS (
  SELECT ticker, company, report_date, filing_date,
         COUNT_IF(DAYOFWEEKISO(DATEADD('day', g.value::INT, report_date)) <= 5) AS business_days
  FROM originals,
       LATERAL FLATTEN(input => ARRAY_GENERATE_RANGE(1, DATEDIFF('day', report_date, filing_date) + 1),
                       OUTER => TRUE) g
  GROUP BY ticker, company, report_date, filing_date
)
SELECT ticker, company, report_date, filing_date,
       IFF(report_date IS NULL, NULL, business_days) AS business_days,
       CASE
         WHEN report_date IS NULL THEN 'No report date'
         WHEN business_days <= 4  THEN 'Within 4 days'
         ELSE 'Over 4 days'
       END AS status
FROM counted
ORDER BY business_days DESC NULLS LAST, ticker;
