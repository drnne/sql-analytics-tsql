/*==============================================================================
Dr Nneoma O

Purpose: I use this query to generate statistical inputs for SPC (Statistical Process
Control) charts used in infection surveillance and governance reporting.

- Includes days with zero cases)
- Split by department
- Split by organism
- Aligned to the NHS fiscal year (1 April to 31 March).

Baseline = previous fiscal year.
Current FY = fiscal year containing today.

Why include zero-case days?
--------------------------
For SPC, I want the process distribution based on all days in the period.
If I only keep days where cases occurred, I bias the mean upwards and distort
the standard deviation (and therefore the 2σ / 3σ limits).

UK date handling
----------------
- No ambiguous date strings
- Fiscal boundaries derived via DATEFROMPARTS

==============================================================================*/

DECLARE @AsOfDate date = CAST(GETDATE() AS date);

DECLARE @CurrentFYStart date =
    CASE
        WHEN @AsOfDate >= DATEFROMPARTS(YEAR(@AsOfDate), 4, 1)
            THEN DATEFROMPARTS(YEAR(@AsOfDate), 4, 1)
        ELSE DATEFROMPARTS(YEAR(@AsOfDate) - 1, 4, 1)
    END;

DECLARE @CurrentFYEnd date = DATEADD(DAY, -1, DATEADD(YEAR, 1, @CurrentFYStart));

DECLARE @BaselineFYStart date = DATEADD(YEAR, -1, @CurrentFYStart);
DECLARE @BaselineFYEnd   date = DATEADD(DAY, -1, DATEADD(YEAR, 1, @BaselineFYStart));

/*------------------------------------------------------------------------------
I use a Numbers CTE to generate a calendar of days (avoids needing a DateDim).
If you already have a Date Dimension, use that instead (it’s usually faster and
more consistent across the model).
------------------------------------------------------------------------------*/
WITH Numbers AS (
    /* 0..9999 should be plenty; fiscal year needs max 366 */
    SELECT TOP (10000)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
    FROM sys.all_objects
),
BaselineCalendar AS (
    SELECT
        DATEADD(DAY, n, @BaselineFYStart) AS ActivityDate
    FROM Numbers
    WHERE DATEADD(DAY, n, @BaselineFYStart) <= @BaselineFYEnd
),
CurrentCalendar AS (
    SELECT
        DATEADD(DAY, n, @CurrentFYStart) AS ActivityDate
    FROM Numbers
    WHERE DATEADD(DAY, n, @CurrentFYStart) <= @CurrentFYEnd
),

/*------------------------------------------------------------------------------
1) Define the “series list” we care about (Department + Organism combinations)
   - I derive these from baseline OR current FY activity so we don’t miss new
     combinations, but still allow zeros across the date range.
------------------------------------------------------------------------------*/
SeriesList AS (
    SELECT DISTINCT
        dd.SiteName,
        dd.DepartmentName,
        od.OrganismName
    FROM dbo.InfectionEvents ie
    LEFT JOIN dbo.DepartmentDim dd ON dd.DepartmentKey = ie.DepartmentKey
    LEFT JOIN dbo.OrganismDim  od ON od.OrganismKey  = ie.OrganismKey
    WHERE
        ie.CollectionDate IS NOT NULL
        AND CAST(ie.CollectionDate AS date) >= @BaselineFYStart
        AND CAST(ie.CollectionDate AS date) <= @CurrentFYEnd
),

/*------------------------------------------------------------------------------
2) Daily observed counts for baseline FY (only days where something happened)
------------------------------------------------------------------------------*/
BaselineObserved AS (
    SELECT
        CAST(ie.CollectionDate AS date) AS ActivityDate,
        dd.SiteName,
        dd.DepartmentName,
        od.OrganismName,
        COUNT(*) AS DailyCases
    FROM dbo.InfectionEvents ie
    LEFT JOIN dbo.DepartmentDim dd ON dd.DepartmentKey = ie.DepartmentKey
    LEFT JOIN dbo.OrganismDim  od ON od.OrganismKey  = ie.OrganismKey
    WHERE
        ie.CollectionDate IS NOT NULL
        AND CAST(ie.CollectionDate AS date) >= @BaselineFYStart
        AND CAST(ie.CollectionDate AS date) <= @BaselineFYEnd
    GROUP BY
        CAST(ie.CollectionDate AS date),
        dd.SiteName,
        dd.DepartmentName,
        od.OrganismName
),

/*------------------------------------------------------------------------------
3) Baseline daily series INCLUDING zero-case days:
   Calendar (all baseline dates) x SeriesList (all dept/organism combos)
   then LEFT JOIN observed counts; missing becomes 0.
------------------------------------------------------------------------------*/
BaselineDailyComplete AS (
    SELECT
        cal.ActivityDate,
        s.SiteName,
        s.DepartmentName,
        s.OrganismName,
        ISNULL(o.DailyCases, 0) AS DailyCases
    FROM BaselineCalendar cal
    CROSS JOIN SeriesList s
    LEFT JOIN BaselineObserved o
        ON o.ActivityDate = cal.ActivityDate
        AND o.SiteName = s.SiteName
        AND o.DepartmentName = s.DepartmentName
        AND o.OrganismName = s.OrganismName
),

/*------------------------------------------------------------------------------
4) SPC parameters per Department + Organism from the COMPLETE baseline series
------------------------------------------------------------------------------*/
BaselineSPC AS (
    SELECT
        SiteName,
        DepartmentName,
        OrganismName,

        COUNT(*) AS BaselineDaysUsed,

        AVG(CAST(DailyCases AS decimal(18,6)))   AS MeanDailyCases,
        STDEV(CAST(DailyCases AS decimal(18,6))) AS StdDevDailyCases,

        AVG(CAST(DailyCases AS decimal(18,6)))
            + (2 * STDEV(CAST(DailyCases AS decimal(18,6))))
            AS UpperWarningLimit,

        AVG(CAST(DailyCases AS decimal(18,6)))
            + (3 * STDEV(CAST(DailyCases AS decimal(18,6))))
            AS UpperControlLimit
    FROM BaselineDailyComplete
    GROUP BY
        SiteName, DepartmentName, OrganismName
),

/*------------------------------------------------------------------------------
5) Current FY observed counts (only days where something happened)
------------------------------------------------------------------------------*/
CurrentObserved AS (
    SELECT
        CAST(ie.CollectionDate AS date) AS ActivityDate,
        dd.SiteName,
        dd.DepartmentName,
        od.OrganismName,
        COUNT(*) AS DailyCases
    FROM dbo.InfectionEvents ie
    LEFT JOIN dbo.DepartmentDim dd ON dd.DepartmentKey = ie.DepartmentKey
    LEFT JOIN dbo.OrganismDim  od ON od.OrganismKey  = ie.OrganismKey
    WHERE
        ie.CollectionDate IS NOT NULL
        AND CAST(ie.CollectionDate AS date) >= @CurrentFYStart
        AND CAST(ie.CollectionDate AS date) <= @CurrentFYEnd
    GROUP BY
        CAST(ie.CollectionDate AS date),
        dd.SiteName,
        dd.DepartmentName,
        od.OrganismName
),

/*------------------------------------------------------------------------------
6) Current FY complete daily series INCLUDING zero-case days
------------------------------------------------------------------------------*/
CurrentDailyComplete AS (
    SELECT
        cal.ActivityDate,
        s.SiteName,
        s.DepartmentName,
        s.OrganismName,
        ISNULL(o.DailyCases, 0) AS DailyCases
    FROM CurrentCalendar cal
    CROSS JOIN SeriesList s
    LEFT JOIN CurrentObserved o
        ON o.ActivityDate = cal.ActivityDate
        AND o.SiteName = s.SiteName
        AND o.DepartmentName = s.DepartmentName
        AND o.OrganismName = s.OrganismName
),

/*------------------------------------------------------------------------------
7) Apply baseline SPC limits to current FY, and flag breaches
------------------------------------------------------------------------------*/
SPCFlagged AS (
    SELECT
        c.ActivityDate,
        CONVERT(char(7), DATEFROMPARTS(YEAR(c.ActivityDate), MONTH(c.ActivityDate), 1), 120) AS YearMonth,

        c.SiteName,
        c.DepartmentName,
        c.OrganismName,

        c.DailyCases,

        s.BaselineDaysUsed,
        s.MeanDailyCases,
        s.StdDevDailyCases,
        s.UpperWarningLimit,
        s.UpperControlLimit,

        CASE
            WHEN s.UpperWarningLimit IS NULL THEN 0
            WHEN CAST(c.DailyCases AS decimal(18,6)) >= s.UpperWarningLimit THEN 1
            ELSE 0
        END AS IsWarningBreached,

        CASE
            WHEN s.UpperControlLimit IS NULL THEN 0
            WHEN CAST(c.DailyCases AS decimal(18,6)) >= s.UpperControlLimit THEN 1
            ELSE 0
        END AS IsControlBreached,

        CASE
            WHEN s.UpperControlLimit IS NULL THEN N'No baseline available'
            WHEN CAST(c.DailyCases AS decimal(18,6)) >= s.UpperControlLimit THEN N'Control limit breached'
            WHEN CAST(c.DailyCases AS decimal(18,6)) >= s.UpperWarningLimit THEN N'Warning limit breached'
            ELSE N'Within expected variation'
        END AS SPCStatus,

        /* Fiscal year labels (handy for titles/tooltips) */
        CONCAT(N'FY', RIGHT(CAST(YEAR(@CurrentFYStart) AS nvarchar(4)), 2), N'/', RIGHT(CAST(YEAR(@CurrentFYEnd) AS nvarchar(4)), 2)) AS CurrentFYLabel,
        CONCAT(N'FY', RIGHT(CAST(YEAR(@BaselineFYStart) AS nvarchar(4)), 2), N'/', RIGHT(CAST(YEAR(@BaselineFYEnd) AS nvarchar(4)), 2)) AS BaselineFYLabel,

        @CurrentFYStart  AS CurrentFYStart,
        @CurrentFYEnd    AS CurrentFYEnd,
        @BaselineFYStart AS BaselineFYStart,
        @BaselineFYEnd   AS BaselineFYEnd
    FROM CurrentDailyComplete c
    LEFT JOIN BaselineSPC s
        ON s.SiteName = c.SiteName
        AND s.DepartmentName = c.DepartmentName
        AND s.OrganismName = c.OrganismName
)

SELECT
    ActivityDate,
    YearMonth,

    SiteName,
    DepartmentName,
    OrganismName,

    DailyCases,

    BaselineDaysUsed,
    MeanDailyCases,
    StdDevDailyCases,
    UpperWarningLimit,
    UpperControlLimit,

    IsWarningBreached,
    IsControlBreached,
    SPCStatus,

    CurrentFYLabel,
    BaselineFYLabel,
    CurrentFYStart,
    CurrentFYEnd,
    BaselineFYStart,
    BaselineFYEnd
FROM SPCFlagged
ORDER BY
    ActivityDate,
    SiteName,
    DepartmentName,
    OrganismName;
