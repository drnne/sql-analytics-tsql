/*==============================================================================
Dr Nneoma O

Purpose: I use this query to calculate a true 7-day rolling average of cases, 
ensuring that days with zero cases are included in the calculation.

Why zero-case days matter
-------------------------
If zero-case days are excluded:
- The rolling average is biased upwards
- Apparent trends can be exaggerated
- SPC and governance interpretations become unreliable

By generating a complete calendar and left-joining observed cases, I ensure:
- One row per calendar day
- Zero activity is treated as zero, not missing data
- The rolling window always represents 7 calendar days

UK date handling
----------------
- Dates are handled using DATEFROMPARTS / DATEADD
- No ambiguous dd/mm/yyyy literals are used

==============================================================================*/

DECLARE @StartDate date =
    (SELECT MIN(CAST(CollectionDate AS date)) FROM dbo.InfectionEvents);

DECLARE @EndDate date =
    (SELECT MAX(CAST(CollectionDate AS date)) FROM dbo.InfectionEvents);

/*------------------------------------------------------------------------------
1) Generate a continuous calendar covering the full data range
------------------------------------------------------------------------------*/
WITH Numbers AS (
    SELECT TOP (10000)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
    FROM sys.all_objects
),
Calendar AS (
    SELECT
        DATEADD(DAY, n, @StartDate) AS CollectionDate
    FROM Numbers
    WHERE DATEADD(DAY, n, @StartDate) <= @EndDate
),

/*------------------------------------------------------------------------------
2) Aggregate observed infection cases by calendar day
------------------------------------------------------------------------------*/
ObservedDailyCases AS (
    SELECT
        CAST(CollectionDate AS date) AS CollectionDate,
        COUNT(*) AS DailyCases
    FROM dbo.InfectionEvents
    WHERE CollectionDate IS NOT NULL
    GROUP BY
        CAST(CollectionDate AS date)
),

/*------------------------------------------------------------------------------
3) Combine calendar with observed data to include zero-case days
------------------------------------------------------------------------------*/
CompleteDailySeries AS (
    SELECT
        c.CollectionDate,
        ISNULL(o.DailyCases, 0) AS DailyCases
    FROM Calendar c
    LEFT JOIN ObservedDailyCases o
        ON o.CollectionDate = c.CollectionDate
),

/*------------------------------------------------------------------------------
4) Calculate the 7-day rolling average over calendar days
------------------------------------------------------------------------------*/
Rolling7Day AS (
    SELECT
        CollectionDate,
        DailyCases,

        AVG(CAST(DailyCases AS decimal(18,6))) OVER (
            ORDER BY CollectionDate
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS Rolling7DayAverage
    FROM CompleteDailySeries
)

SELECT
    CollectionDate,
    DailyCases,
    Rolling7DayAverage
FROM Rolling7Day
ORDER BY
    CollectionDate;

