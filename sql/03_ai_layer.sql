-- =====================================================================
-- BreachWatch: analytics + RAG layer on the full 44-filing set
-- Builds into the MARTS schema so the ANALYTICS schema (22-filing
-- prototype) is left untouched.
--
-- Run ONE STEP AT A TIME (highlight the step, then Run) and check the
-- result before moving on.
-- =====================================================================
USE WAREHOUSE COMPUTE_WH;
USE SCHEMA BREACHWATCH.MARTS;

-- ---------------------------------------------------------------------
-- STEP 1. Clean text and pull out the Item 1.05 section
--   HTML tags -> removed, HTML entities -> space, whitespace collapsed.
--   Section = from "Item 1.05" to "Item 9.01" (or "Signature").
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FILINGS AS
WITH base AS (
  SELECT
    m.record:accession_number::STRING AS accession_number,
    m.record:ticker::STRING           AS ticker,
    m.record:company_name::STRING     AS company_name,
    m.record:form_type::STRING        AS form_type,
    m.record:filing_date::DATE        AS filing_date,
    m.record:report_date::DATE        AS report_date,
    m.record:source_url::STRING       AS source_url,
    TRIM(REGEXP_REPLACE(
           REGEXP_REPLACE(
             REGEXP_REPLACE(d.raw_html, '<[^>]+>', ' '),
           '&[#a-zA-Z0-9]+;', ' '),
         '\\s+', ' ')) AS full_text
  FROM BREACHWATCH.RAW.FILINGS_METADATA m
  JOIN BREACHWATCH.RAW.FILING_DOCUMENTS d
    ON d.accession_number = m.record:accession_number::STRING
),
pos AS (
  SELECT *,
         POSITION('item 1.05', LOWER(full_text))                    AS start_pos
  FROM base
),
ends AS (
  SELECT *,
         IFF(start_pos > 0, POSITION('item 9.01', LOWER(full_text), start_pos + 9), 0) AS end_901,
         IFF(start_pos > 0, POSITION('signature', LOWER(full_text), start_pos + 9), 0) AS end_sig
  FROM pos
)
SELECT
  accession_number, ticker, company_name, form_type, filing_date, report_date,
  source_url, full_text,
  start_pos > 0 AS item_105_found,
  CASE
    WHEN start_pos = 0 THEN LEFT(full_text, 15000)
    WHEN end_901 > 0   THEN SUBSTR(full_text, start_pos, end_901 - start_pos)
    WHEN end_sig > 0   THEN SUBSTR(full_text, start_pos, end_sig - start_pos)
    ELSE SUBSTR(full_text, start_pos, 15000)
  END AS section_text
FROM ends;

-- Check: expect 44 rows, most with item_105_found = TRUE
SELECT ticker, form_type, filing_date, item_105_found,
       LENGTH(section_text) AS section_chars, LEFT(section_text, 200) AS preview
FROM FILINGS ORDER BY ticker, filing_date;


-- ---------------------------------------------------------------------
-- STEP 2. Chunk the Item 1.05 text and embed every chunk (Cortex)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FILING_CHUNKS AS
SELECT
  f.accession_number, f.ticker, f.company_name, f.form_type, f.filing_date,
  c.index          AS chunk_index,
  c.value::STRING  AS chunk_text,
  SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m', c.value::STRING) AS embedding
FROM FILINGS f,
     LATERAL FLATTEN(input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
                                f.section_text, 'none', 1200, 150)) c;

-- Check: chunk counts per company
SELECT ticker, COUNT(*) AS chunks FROM FILING_CHUNKS GROUP BY ticker ORDER BY chunks DESC;


-- ---------------------------------------------------------------------
-- STEP 3. LLM extracts the incident dates from each filing (Cortex)
--   Raw model output is kept so every extraction can be audited.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE INCIDENT_DATE_EXTRACTIONS AS
SELECT
  accession_number, ticker, company_name, form_type, filing_date, report_date,
  SNOWFLAKE.CORTEX.COMPLETE('llama3.3-70b', CONCAT(
    'You read SEC Form 8-K Item 1.05 cybersecurity incident disclosures. ',
    'Return ONLY a JSON object and no other text, with these keys: ',
    '"discovery_date": the date the company first detected or became aware of the incident, as YYYY-MM-DD; ',
    '"materiality_date": the date the company determined the incident was material, as YYYY-MM-DD; ',
    '"evidence": a short exact quote from the text that states the materiality date, or null. ',
    'Use null for any date the text does not explicitly state. Do not guess or infer dates. ',
    'Filing text: ', LEFT(section_text, 12000))) AS llm_raw
FROM FILINGS;

-- Check: look at a few raw outputs
SELECT ticker, form_type, llm_raw FROM INCIDENT_DATE_EXTRACTIONS LIMIT 5;


-- ---------------------------------------------------------------------
-- STEP 4. Incidents with the timeliness verdict (original 8-Ks only)
--   Clock starts at the LLM-extracted materiality date when the filing
--   states one; otherwise falls back to the cover-page report date.
--   Weekends skipped; federal holidays not yet handled.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE INCIDENTS AS
WITH parsed AS (
  SELECT *, TRY_PARSE_JSON(REGEXP_SUBSTR(llm_raw, '\\{.*\\}', 1, 1, 's')) AS j
  FROM INCIDENT_DATE_EXTRACTIONS
  WHERE form_type = '8-K'
),
dates AS (
  SELECT
    accession_number, ticker, company_name, filing_date, report_date,
    TRY_TO_DATE(j:discovery_date::STRING)   AS discovery_date,
    TRY_TO_DATE(j:materiality_date::STRING) AS materiality_date,
    j:evidence::STRING                      AS evidence,
    COALESCE(TRY_TO_DATE(j:materiality_date::STRING), report_date) AS clock_start,
    IFF(TRY_TO_DATE(j:materiality_date::STRING) IS NOT NULL,
        'LLM: materiality date stated in filing',
        'Fallback: cover-page report date') AS date_source
  FROM parsed
),
counted AS (
  SELECT d.*,
         COUNT_IF(DAYOFWEEKISO(DATEADD('day', g.value::INT, d.clock_start)) <= 5) AS bd
  FROM dates d,
       LATERAL FLATTEN(input => ARRAY_GENERATE_RANGE(1, DATEDIFF('day', d.clock_start, d.filing_date) + 1),
                       OUTER => TRUE) g
  GROUP BY ALL
)
SELECT
  ticker, company_name, discovery_date, materiality_date, report_date, filing_date,
  date_source,
  IFF(clock_start IS NULL OR clock_start > filing_date, NULL, bd) AS business_days_to_file,
  CASE
    WHEN clock_start IS NULL         THEN 'Can''t tell'
    WHEN clock_start > filing_date   THEN 'Check: date after filing'
    WHEN bd <= 4                     THEN 'On time'
    ELSE 'Late'
  END AS status,
  evidence,
  accession_number
FROM counted;

-- The demo result
SELECT * FROM INCIDENTS ORDER BY business_days_to_file DESC NULLS LAST, ticker;

-- Summary: how often does the filing actually state the materiality date?
SELECT date_source, status, COUNT(*) AS incidents
FROM INCIDENTS GROUP BY date_source, status ORDER BY incidents DESC;


-- ---------------------------------------------------------------------
-- STEP 5. Semantic search (RAG retrieval)
-- ---------------------------------------------------------------------
SET question = 'ransomware attack disrupted operations';

SELECT company_name, form_type, filing_date, LEFT(chunk_text, 300) AS passage,
       VECTOR_COSINE_SIMILARITY(embedding,
         SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m', $question)) AS score
FROM FILING_CHUNKS
ORDER BY score DESC
LIMIT 5;


-- ---------------------------------------------------------------------
-- STEP 6. Full RAG answer: retrieve top passages, LLM answers with citations
-- ---------------------------------------------------------------------
SET question = 'Which companies said the incident disrupted their operations, and how?';

WITH top_chunks AS (
  SELECT company_name, accession_number, chunk_text,
         VECTOR_COSINE_SIMILARITY(embedding,
           SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m', $question)) AS score
  FROM FILING_CHUNKS
  ORDER BY score DESC
  LIMIT 6
)
SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.3-70b', CONCAT(
  'Answer the question using ONLY the SEC filing excerpts below. ',
  'Name the company for every fact. If the excerpts do not answer the question, say so.\n\n',
  'Question: ', $question, '\n\nExcerpts:\n',
  LISTAGG(CONCAT('[', company_name, ' | ', accession_number, '] ', chunk_text), '\n\n')
)) AS answer
FROM top_chunks;
