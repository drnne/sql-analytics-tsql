/*==============================================================================
Dr Nneoma O
Infection Thresholds 

Purpose
-------
I use this pattern to identify threshold breaches based on case counts for organism-specific infection cases,
so the results can be consumed in Power BI (or any analytics platform) for drill-down and alerting.

Key idea
--------
1) Infection events stay in the core clinical tables (live / DirectQuery-friendly).
2) Thresholds arrive in a PDF (often from NHS England Report), so I
   stage them into a temporary table for comparison.
3) I aggregate organism case numbers and flag where they exceed the threshold. Similar can be done for rates.

UK date/time note
-----------------
- I anchor months using DATEFROMPARTS(YEAR(..), MONTH(..), 1) so grouping is
  stable and unambiguous.
- I avoid dd/mm vs mm/dd issues by never using ambiguous string-to-date formats.

Assumed inputs (dummy)
----------------------
dbo.InfectionEvents:
  - InfectionEventKey, PatientKey, EncounterKey, DepartmentKey, OrganismKey
  - CollectionInstant (datetime2)

dbo.DepartmentDim:
  - DepartmentKey, DepartmentName, SiteName

dbo.OrganismDim:
  - OrganismKey, OrganismName

dbo.BedDaysFact (or similar denominator table):
  - DepartmentKey, BedDayDate (date), BedDays (int)
  (If you don’t have bed days, you can swap this for admissions/occupied beds etc.)

PDF thresholds
--------------
- Threshold values are extracted from the PDF upstream (Power Query, Python,
  ETL tool) and inserted into #ThresholdRules.

==============================================================================*/

DECLARE @StartDate date = DATEFROMPARTS(2025, 01, 01);
DECLARE @EndDate   date = EOMONTH(GETDATE());

/*------------------------------------------------------------------------------
1) Stage thresholds (from PDF) into a temp table
   These thresholds are CASE-BASED, e.g. MonthlyCaseThreshold = 2.
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#ThresholdRules') IS NOT NULL DROP TABLE #ThresholdRules;

CREATE TABLE #ThresholdRules (
    RuleKey              int IDENTITY(1,1) PRIMARY KEY,
    EffectiveFromDate    date          NOT NULL,
    EffectiveToDate      date          NULL,          -- NULL = open ended
    DepartmentName       nvarchar(200) NULL,          -- NULL = applies to all departments
    OrganismName         nvarchar(200) NOT NULL,
    MonthlyCaseThreshold int           NOT NULL,      -- breach when CaseCount >= this
    AmberCaseThreshold   int           NULL,          -- optional warning level added after 2SD
    RedCaseThreshold     int           NULL           -- optional red level (if distinct) 3SD
);

-- Example loads (dummy values) that your PDF extraction step would insert 
INSERT INTO #ThresholdRules (EffectiveFromDate, EffectiveToDate, DepartmentName, OrganismName, MonthlyCaseThreshold, AmberCaseThreshold, RedCaseThreshold)
VALUES
('2025-01-01', NULL, NULL, N'MRSA', 2, 1, 2),       -- hospital-wide: 2+ cases/month = breach
('2025-01-01', NULL, N'ICU', N'E. coli', 5, 4, 5),     -- ICU-specific: 5+ cases/month
('2025-01-01', NULL, N'Surgery', N'C. diff', 3, 2, 3);     -- Surgery-specific: 3+ cases/month


/*------------------------------------------------------------------------------
2) Base infection events with explicit month anchor for grouping
------------------------------------------------------------------------------*/
WITH BaseEvents AS (
    SELECT
        ie.InfectionEventKey,
        ie.PatientKey,
        ie.DepartmentKey,
        ie.OrganismKey,
        ie.CollectionInstant,
        DATEFROMPARTS(YEAR(CAST(ie.CollectionInstant AS date)), MONTH(CAST(ie.CollectionInstant AS date)), 1) AS MonthStartDate
    FROM dbo.InfectionEvents ie
    WHERE
        ie.CollectionInstant IS NOT NULL
        AND CAST(ie.CollectionInstant AS date) >= @StartDate
        AND CAST(ie.CollectionInstant AS date) <= @EndDate
),

/*------------------------------------------------------------------------------
3) Enrich with Department + Organism for drill-down in Power BI
------------------------------------------------------------------------------*/
EnrichedEvents AS (
    SELECT
        b.MonthStartDate,
        b.InfectionEventKey,
        d.SiteName,
        d.DepartmentName,
        o.OrganismName
    FROM BaseEvents b
    LEFT JOIN dbo.DepartmentDim d
        ON d.DepartmentKey = b.DepartmentKey
    LEFT JOIN dbo.OrganismDim o
        ON o.OrganismKey = b.OrganismKey
),

/*------------------------------------------------------------------------------
4) Monthly case counts (numerator only)
   Here, COUNT(*) is the number of infection events (cases) in the group.
------------------------------------------------------------------------------*/
MonthlyCases AS (
    SELECT
        MonthStartDate,
        CONVERT(char(7), MonthStartDate, 120) AS YearMonth,
        SiteName,
        DepartmentName,
        OrganismName,
        COUNT(*) AS CaseCount
    FROM EnrichedEvents
    GROUP BY
        MonthStartDate,
        CONVERT(char(7), MonthStartDate, 120),
        SiteName,
        DepartmentName,
        OrganismName
),

/*------------------------------------------------------------------------------
5) Match each monthly case row to the correct threshold rule
   - Department-specific rule overrides global rule (DepartmentName IS NULL)
   - Effective date range is honoured
------------------------------------------------------------------------------*/
MatchedRules AS (
    SELECT
        mc.*,
        tr.RuleKey,
        tr.MonthlyCaseThreshold,
        tr.AmberCaseThreshold,
        tr.RedCaseThreshold,

        ROW_NUMBER() OVER (
            PARTITION BY mc.MonthStartDate, mc.SiteName, mc.DepartmentName, mc.OrganismName
            ORDER BY
                CASE WHEN tr.DepartmentName IS NOT NULL THEN 0 ELSE 1 END,  -- prefer dept-specific
                tr.EffectiveFromDate DESC
        ) AS RuleRank
    FROM MonthlyCases mc
    JOIN #ThresholdRules tr
        ON tr.OrganismName = mc.OrganismName
        AND (tr.DepartmentName = mc.DepartmentName OR tr.DepartmentName IS NULL)
        AND mc.MonthStartDate >= tr.EffectiveFromDate
        AND (tr.EffectiveToDate IS NULL OR mc.MonthStartDate <= tr.EffectiveToDate)
),

/*------------------------------------------------------------------------------
6) Produce breach flags using CASE (case-count thresholds)
------------------------------------------------------------------------------*/
BreachFlags AS (
    SELECT
        MonthStartDate,
        YearMonth,
        SiteName,
        DepartmentName,
        OrganismName,
        CaseCount,

        RuleKey,
        MonthlyCaseThreshold,
        AmberCaseThreshold,
        RedCaseThreshold,

        -- Clean boolean flag for Power BI 
        CASE
            WHEN RedCaseThreshold IS NOT NULL AND CaseCount >= RedCaseThreshold THEN 1
            WHEN RedCaseThreshold IS NULL AND CaseCount >= MonthlyCaseThreshold THEN 1
            ELSE 0
        END AS IsThresholdBreached,

        -- Friendly severity label for visuals 
        CASE
            WHEN RedCaseThreshold IS NOT NULL AND CaseCount >= RedCaseThreshold THEN N'Red'
            WHEN AmberCaseThreshold IS NOT NULL AND CaseCount >= AmberCaseThreshold THEN N'Amber'
            WHEN CaseCount >= MonthlyCaseThreshold THEN N'Breach'
            ELSE N'Within limits'
        END AS BreachStatus
    FROM MatchedRules
    WHERE RuleRank = 1
)

SELECT
    YearMonth,
    SiteName,
    DepartmentName,
    OrganismName,

    CaseCount,

    MonthlyCaseThreshold,
    AmberCaseThreshold,
    RedCaseThreshold,

    IsThresholdBreached,
    BreachStatus,

    RuleKey,
    MonthStartDate
FROM BreachFlags
ORDER BY
    YearMonth,
    SiteName,
    DepartmentName,
    OrganismName;


