/*==============================================================================
Dr Nneoma O
31/12/2025

Purpose
-------
I use this query to calculate monthly infection KPIs for reporting and
dashboarding (e.g., Power BI), whilst ensuring:
  - Safe date handling (UK) 
  - Drill-down by Hospital Department (where the infections are occurring)
  - Drill-down by Organism (what is causing the infection)
  - Enrichment via comorbidities (e.g., Diabetes + Hypertension) to show how
    linking CTEs creates a richer analytical dataset.

Why I’ve written it this way
----------------------------
- I keep each step in a CTE so I can quickly validate outputs and isolate issues.
- I aggregate at month-start (DATEFROMPARTS) so the time component never causes
  accidental mis-grouping.
- I avoid ambiguous date strings. If I need parameters, I use DATE variables.
- This structure is designed to work well with DirectQuery / live connections
  (I’m explicit with joins and grouping keys).

Assumed Tables (dummy names used, please adjust to your schema if replicating)
----------------------------------------------------
dbo.InfectionEvents
  - InfectionEventKey (PK)
  - PatientKey
  - EncounterKey
  - DepartmentKey
  - OrganismKey
  - CollectionInstant (datetime2)  -- when the specimen/event was recorded

dbo.DepartmentDim
  - DepartmentKey (PK)
  - DepartmentName
  - SiteName (optional)

dbo.OrganismDim
  - OrganismKey (PK)
  - OrganismName

dbo.PatientDim
  - PatientKey (PK)
  - NHSNumber (optional), DOB (optional)

dbo.PatientComorbidity
  - PatientKey
  - ConditionName  -- e.g. 'Diabetes', 'Hypertension'
  - ConditionCode  -- optional

UK Date/Time Note
-----------------
Hospitals in the UK typically operate on UK local time. If your CollectionInstant
is stored in UTC and you need UK local time, you can convert it using AT TIME ZONE.
I’ve left an optional example in the BaseEvents CTE.

==============================================================================*/

--I keep the date visible and before the rest of code by declaring to start
DECLARE @StartDate date = DATEFROMPARTS(2025, 01, 01) -- less ambiguous than using where filter due to differing date nomenclature;
DECLARE @EndDate   date = EOMONTH(GETDATE());  -- current month end (UK reporting often uses month end)

-- 1) Base infection events with explicit month handling 
WITH BaseEvents AS (
    SELECT
        ie.InfectionEventKey,
        ie.PatientKey,
        ie.EncounterKey,
        ie.DepartmentKey,
        ie.OrganismKey,
        -- I keep the raw timestamp for auditability 
        ie.CollectionInstant,
        /* OPTIONAL (only if CollectionInstant is UTC and you need UK local time)
           CAST((ie.CollectionInstant AT TIME ZONE 'UTC' AT TIME ZONE 'GMT Standard Time') AS datetime2) AS CollectionInstant_UK,
        */
        -- I anchor to the first day of the month for clean monthly grouping, though can do this via date table link if available
        DATEFROMPARTS(YEAR(CAST(ie.CollectionInstant AS date)), MONTH(CAST(ie.CollectionInstant AS date)), 1) AS MonthStartDate
    FROM dbo.InfectionEvents ie
    WHERE
        ie.CollectionInstant IS NOT NULL
        AND CAST(ie.CollectionInstant AS date) >= @StartDate
        AND CAST(ie.CollectionInstant AS date) <= @EndDate
),

-- 2) Enrich with Department + Organism so Power BI can drill down properly 
EnrichedEvents AS (
    SELECT
        b.MonthStartDate,
        b.InfectionEventKey,
        b.PatientKey,
        b.EncounterKey,
        b.CollectionInstant,

        d.DepartmentKey,
        d.DepartmentName,
        d.SiteName,

        o.OrganismKey,
        o.OrganismName
    FROM BaseEvents b
    LEFT JOIN dbo.DepartmentDim d
        ON d.DepartmentKey = b.DepartmentKey
    LEFT JOIN dbo.OrganismDim o
        ON o.OrganismKey = b.OrganismKey
),

/* 3) Build comorbidity flags (Diabetes/Hypertension) at patient level
      so I can slice KPI outputs without duplicating infection rows. */
ComorbidityFlags AS (
    SELECT
        pc.PatientKey,
        MAX(CASE WHEN pc.ConditionName IN ('Diabetes', 'Diabetes Mellitus') THEN 1 ELSE 0 END) AS HasDiabetes,
        MAX(CASE WHEN pc.ConditionName IN ('Hypertension', 'High Blood Pressure') THEN 1 ELSE 0 END) AS HasHypertension
    FROM dbo.PatientComorbidity pc
    GROUP BY
        pc.PatientKey
),

-- 4) Final grain: one row per infection event, now enriched with comorbidity flags 
EventWide AS (
    SELECT
        e.MonthStartDate,
        e.InfectionEventKey,
        e.PatientKey,
        e.EncounterKey,
        e.CollectionInstant,

        e.DepartmentKey,
        e.DepartmentName,
        e.SiteName,

        e.OrganismKey,
        e.OrganismName,

        -- I default to 0 when comorbidity records are missing, best practice with clinical records 
        ISNULL(c.HasDiabetes, 0) AS HasDiabetes, 
        ISNULL(c.HasHypertension, 0) AS HasHypertension
    FROM EnrichedEvents e
    LEFT JOIN ComorbidityFlags c
        ON c.PatientKey = e.PatientKey
),

-- 5) Monthly KPI outputs (counts) with drilldown dimensions 
MonthlyKPI AS (
    SELECT
        /* YYYY-MM is unambiguous (no date for misinterpretation) and sorts correctly ->
        style 120 produces the ISO format (YYYY-MM-DD) and with Char(7) we only keep first 7 (YYYY-MM)*/
        
        CONVERT(char(7), MonthStartDate, 120) AS YearMonth,
        SiteName,
        DepartmentName,
        OrganismName,
        COUNT(*) AS InfectionCount, --Includes NULL values which may be in the dataset, avoid undercounting

        /* These extra KPIs often land well in dashboards */
        COUNT(DISTINCT PatientKey) AS DistinctPatients,
        COUNT(DISTINCT EncounterKey) AS DistinctEncounters,

        /* Comorbidity slices */
        SUM(CASE WHEN HasDiabetes = 1 THEN 1 ELSE 0 END) AS InfectionsWithDiabetes,
        SUM(CASE WHEN HasHypertension = 1 THEN 1 ELSE 0 END) AS InfectionsWithHypertension,
        SUM(CASE WHEN HasDiabetes = 1 AND HasHypertension = 1 THEN 1 ELSE 0 END) AS InfectionsWithDiabetesAndHypertension
    FROM EventWide
    GROUP BY
        CONVERT(char(7), MonthStartDate, 120),
        SiteName,
        DepartmentName,
        OrganismName
)

SELECT
    YearMonth,
    SiteName,
    DepartmentName,
    OrganismName,
    InfectionCount,
    DistinctPatients,
    DistinctEncounters,
    InfectionsWithDiabetes,
    InfectionsWithHypertension,
    InfectionsWithDiabetesAndHypertension
FROM MonthlyKPI
ORDER BY
    YearMonth,
    SiteName,
    DepartmentName,
    OrganismName;
