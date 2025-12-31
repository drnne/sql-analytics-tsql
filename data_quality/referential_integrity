/*==============================================================================
Dr Nneoma O

Purpose: I use this check to identify orphaned event records where, for example, the
fact table contains a PatientID that does not exist in the Patient dim table

This validates referential integrity between:
- InfectionEvents (fact)
- PatientDim (dimension)

Why this matters
----------------
Orphaned records indicate:
- ETL or load sequencing issues
- Failed or partial dimension loads
- Historical patient records being deleted or archived incorrectly

If left unaddressed, these records:
- Disappear from reports when INNER JOINs are used
- Cause under-counting in infection KPIs
- Undermine confidence in published figures

Design choice
-------------
I deliberately use a LEFT JOIN and then filter for NULLs in the dimension to
surface only the broken relationships.

==============================================================================*/

SELECT
    f.EventID,
    f.PatientID
FROM dbo.InfectionEvents f
LEFT JOIN dbo.PatientDim p
    ON p.PatientID = f.PatientID
WHERE
    p.PatientID IS NULL;
