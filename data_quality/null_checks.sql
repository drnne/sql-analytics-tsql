/*==============================================================================
Dr Nneoma O 

Purpose: I use this check to identify event records that are incomplete
and therefore not safe for reporting or KPI calculations.

Specifically, I am checking for missing values in critical fields that are
required for:
- Temporal analysis (e.g CollectionDate)
- Patient-level linkage and governance (e.g PatientID)

Why this matters
----------------
Records with missing critical fields:
- Cannot be reliably included in trend analysis
- Can distort SPC calculations
- Create audit and data quality risks if reported

Rather than silently excluding these records downstream, I explicitly quantify
them so data quality issues are:
- Visible
- Measurable
- Defensible in governance discussions

UK date handling
----------------
I do not attempt to infer or default missing dates. Any NULL CollectionDate is
treated as a data quality failure.

==============================================================================*/

SELECT
    COUNT(*) AS NullCriticalFieldCount
FROM dbo.InfectionEvents
WHERE
    CollectionDate IS NULL
    OR PatientID IS NULL;

