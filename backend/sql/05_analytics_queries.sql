-- =============================================================================
-- Urban Pulse Analytics — Advanced Analytics Queries
-- This file is a standalone SQL showcase for portfolio / interview purposes
-- Demonstrates mastery of: Window Functions, CTEs, Subqueries, PIVOT,
--   ROLLUP/CUBE, Recursive CTEs, JSON, String Aggregation, Date Math
-- =============================================================================

USE UrbanPulseAnalytics;
GO

-- =============================================================================
-- QUERY 1: Top N sensors per city by anomaly rate (last 7 days)
--          Window function + conditional aggregation
-- =============================================================================
WITH SensorAnomalyRate AS (
    SELECT
        c.CityName,
        s.SensorCode,
        st.TypeCode             AS SensorType,
        COUNT(*)                AS TotalReadings,
        SUM(CASE WHEN sr.IsAnomaly = 1 THEN 1 ELSE 0 END) AS AnomalyCount,
        CAST(
            100.0 * SUM(CASE WHEN sr.IsAnomaly = 1 THEN 1 ELSE 0 END) / COUNT(*)
        AS DECIMAL(5,2))        AS AnomalyRate_Pct
    FROM       dbo.SensorReading sr
    JOIN       dbo.Sensor        s  ON s.SensorID      = sr.SensorID
    JOIN       dbo.SensorType    st ON st.SensorTypeID  = s.SensorTypeID
    JOIN       dbo.City          c  ON c.CityID         = s.CityID
    WHERE      sr.ReadingAt >= DATEADD(DAY, -7, SYSUTCDATETIME())
    GROUP BY   c.CityName, s.SensorCode, st.TypeCode
),
RankedSensors AS (
    SELECT
        *,
        DENSE_RANK() OVER (PARTITION BY CityName ORDER BY AnomalyRate_Pct DESC) AS CityRank
    FROM SensorAnomalyRate
)
SELECT *
FROM   RankedSensors
WHERE  CityRank <= 3  -- Top 3 problem sensors per city
ORDER BY CityName, CityRank;
GO

-- =============================================================================
-- QUERY 2: Hourly traffic pattern with day-of-week heatmap
--          GROUP BY ROLLUP + PIVOT simulation
-- =============================================================================
SELECT
    DATENAME(WEEKDAY, sr.ReadingAt)                             AS DayOfWeek,
    DATEPART(WEEKDAY,  sr.ReadingAt)                            AS DayNum,
    DATEPART(HOUR,     sr.ReadingAt)                            AS HourOfDay,
    c.CityName,
    ROUND(AVG(sr.ReadingValue), 0)                              AS AvgTraffic,
    ROUND(MAX(sr.ReadingValue), 0)                              AS PeakTraffic,
    COUNT(*)                                                    AS SampleCount,

    -- Peak hour flag
    CASE
        WHEN DATEPART(HOUR, sr.ReadingAt) BETWEEN 6 AND 9  THEN 'MORNING_PEAK'
        WHEN DATEPART(HOUR, sr.ReadingAt) BETWEEN 16 AND 19 THEN 'EVENING_PEAK'
        WHEN DATEPART(HOUR, sr.ReadingAt) BETWEEN 22 AND 23 THEN 'OFF_PEAK'
        WHEN DATEPART(HOUR, sr.ReadingAt) BETWEEN 0 AND 5   THEN 'OFF_PEAK'
        ELSE 'SHOULDER'
    END AS PeriodType

FROM       dbo.SensorReading sr
JOIN       dbo.Sensor        s  ON s.SensorID      = sr.SensorID
JOIN       dbo.SensorType    st ON st.SensorTypeID  = s.SensorTypeID
JOIN       dbo.City          c  ON c.CityID         = s.CityID
WHERE      st.TypeCode      = 'TRAFFIC'
  AND      sr.ReadingAt     >= DATEADD(DAY, -30, SYSUTCDATETIME())
GROUP BY
    DATENAME(WEEKDAY, sr.ReadingAt),
    DATEPART(WEEKDAY,  sr.ReadingAt),
    DATEPART(HOUR,     sr.ReadingAt),
    c.CityName,
    CASE
        WHEN DATEPART(HOUR, sr.ReadingAt) BETWEEN 6 AND 9   THEN 'MORNING_PEAK'
        WHEN DATEPART(HOUR, sr.ReadingAt) BETWEEN 16 AND 19  THEN 'EVENING_PEAK'
        WHEN DATEPART(HOUR, sr.ReadingAt) BETWEEN 22 AND 23  THEN 'OFF_PEAK'
        WHEN DATEPART(HOUR, sr.ReadingAt) BETWEEN 0 AND 5    THEN 'OFF_PEAK'
        ELSE 'SHOULDER'
    END
ORDER BY DayNum, HourOfDay, CityName;
GO

-- =============================================================================
-- QUERY 3: Rolling 3-reading average with deviation from baseline
--          Demonstrates: LAG/LEAD with frames, multiple window specs
-- =============================================================================
WITH ReadingsWithContext AS (
    SELECT
        s.SensorCode,
        c.CityName,
        st.TypeCode     AS SensorType,
        sr.ReadingAt,
        sr.ReadingValue,
        sr.IsAnomaly,

        -- Previous and next readings (for trend direction)
        LAG(sr.ReadingValue,  1) OVER (PARTITION BY sr.SensorID ORDER BY sr.ReadingAt) AS PrevReading,
        LAG(sr.ReadingValue,  2) OVER (PARTITION BY sr.SensorID ORDER BY sr.ReadingAt) AS Prev2Reading,
        LEAD(sr.ReadingValue, 1) OVER (PARTITION BY sr.SensorID ORDER BY sr.ReadingAt) AS NextReading,

        -- 3-reading rolling average (current + 2 prior)
        AVG(sr.ReadingValue) OVER (
            PARTITION BY sr.SensorID
            ORDER BY sr.ReadingAt
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS Rolling3Avg,

        -- Cumulative average (ever-expanding baseline)
        AVG(sr.ReadingValue) OVER (
            PARTITION BY sr.SensorID
            ORDER BY sr.ReadingAt
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS CumulativeAvg,

        -- Standard deviation over last 48 readings
        STDEV(sr.ReadingValue) OVER (
            PARTITION BY sr.SensorID
            ORDER BY sr.ReadingAt
            ROWS BETWEEN 47 PRECEDING AND CURRENT ROW
        ) AS Rolling48StdDev

    FROM       dbo.SensorReading sr
    JOIN       dbo.Sensor        s  ON s.SensorID     = sr.SensorID
    JOIN       dbo.SensorType    st ON st.SensorTypeID = s.SensorTypeID
    JOIN       dbo.City          c  ON c.CityID        = s.CityID
    WHERE      sr.ReadingAt >= DATEADD(HOUR, -24, SYSUTCDATETIME())
)
SELECT
    *,
    ReadingValue - CumulativeAvg                    AS DeviationFromBaseline,
    CASE
        WHEN PrevReading IS NOT NULL AND ReadingValue > PrevReading THEN 'RISING'
        WHEN PrevReading IS NOT NULL AND ReadingValue < PrevReading THEN 'FALLING'
        ELSE 'STABLE'
    END AS TrendDirection,

    -- Z-score using rolling window stats
    CASE
        WHEN Rolling48StdDev > 0
        THEN ROUND((ReadingValue - Rolling3Avg) / Rolling48StdDev, 3)
        ELSE 0
    END AS ZScore

FROM ReadingsWithContext
ORDER BY SensorCode, ReadingAt DESC;
GO

-- =============================================================================
-- QUERY 4: City comparison summary with ROLLUP (subtotals + grand total)
--          Demonstrates: GROUP BY ROLLUP, GROUPING(), COALESCE
-- =============================================================================
SELECT
    COALESCE(c.CityName,    'ALL CITIES')   AS CityName,
    COALESCE(st.TypeCode,   'ALL TYPES')    AS SensorType,
    COUNT(DISTINCT s.SensorID)              AS SensorCount,
    COUNT(sr.ReadingID)                     AS ReadingCount,
    ROUND(AVG(sr.ReadingValue), 2)          AS AvgReading,
    SUM(CASE WHEN sr.IsAnomaly = 1 THEN 1 ELSE 0 END) AS TotalAnomalies,
    ROUND(
        100.0 * SUM(CASE WHEN sr.IsAnomaly = 1 THEN 1 ELSE 0 END)
              / NULLIF(COUNT(sr.ReadingID), 0)
    , 2)                                    AS AnomalyRate_Pct,

    -- Indicate rollup level
    CASE
        WHEN GROUPING(c.CityName) = 1 AND GROUPING(st.TypeCode) = 1 THEN 'GRAND_TOTAL'
        WHEN GROUPING(c.CityName) = 1                                THEN 'TYPE_SUBTOTAL'
        WHEN GROUPING(st.TypeCode) = 1                               THEN 'CITY_SUBTOTAL'
        ELSE 'DETAIL'
    END AS RowType

FROM       dbo.SensorReading sr
JOIN       dbo.Sensor        s  ON s.SensorID      = sr.SensorID
JOIN       dbo.SensorType    st ON st.SensorTypeID  = s.SensorTypeID
JOIN       dbo.City          c  ON c.CityID         = s.CityID
WHERE      sr.ReadingAt >= DATEADD(DAY, -7, SYSUTCDATETIME())
GROUP BY ROLLUP (c.CityName, st.TypeCode)
ORDER BY
    GROUPING(c.CityName),
    GROUPING(st.TypeCode),
    c.CityName,
    st.TypeCode;
GO

-- =============================================================================
-- QUERY 5: Alert SLA compliance report with STRING_AGG
--          Demonstrates: STRING_AGG, DATEDIFF, CASE multi-branch
-- =============================================================================
SELECT
    c.CityName,
    at.TypeName     AS AlertType,
    at.Severity,

    COUNT(*)                                        AS TotalAlerts,
    SUM(CASE WHEN a.IsResolved = 1 THEN 1 ELSE 0 END) AS ResolvedAlerts,
    SUM(CASE WHEN a.IsResolved = 0 THEN 1 ELSE 0 END) AS OpenAlerts,

    -- Resolution time distribution
    SUM(CASE WHEN a.IsResolved = 1
             AND DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt) <= 30
        THEN 1 ELSE 0 END)                          AS ResolvedUnder30Min,

    SUM(CASE WHEN a.IsResolved = 1
             AND DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt) BETWEEN 31 AND 120
        THEN 1 ELSE 0 END)                          AS Resolved31to120Min,

    SUM(CASE WHEN a.IsResolved = 1
             AND DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt) > 120
        THEN 1 ELSE 0 END)                          AS ResolvedOver120Min,

    ROUND(AVG(
        CASE WHEN a.IsResolved = 1
        THEN CAST(DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt) AS FLOAT)
        END
    ), 1)                                           AS AvgResolutionMinutes,

    -- SLA compliance rate (target: resolve within 30 min for severity >= 3)
    ROUND(100.0 *
        SUM(CASE WHEN at.Severity >= 3
                  AND a.IsResolved = 1
                  AND DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt) <= 30
             THEN 1 ELSE 0 END) /
        NULLIF(SUM(CASE WHEN at.Severity >= 3 AND a.IsResolved = 1 THEN 1 ELSE 0 END), 0)
    , 1)                                            AS SLA_CompliancePct,

    -- Aggregate list of sensor codes that fired alerts (for quick triage)
    STRING_AGG(DISTINCT s.SensorCode, ', ')
        WITHIN GROUP (ORDER BY s.SensorCode)        AS InvolvedSensors

FROM       dbo.Alert         a
JOIN       dbo.AlertType     at ON at.AlertTypeID   = a.AlertTypeID
JOIN       dbo.Sensor        s  ON s.SensorID       = a.SensorID
JOIN       dbo.City          c  ON c.CityID         = s.CityID
WHERE      a.AlertRaisedAt  >= DATEADD(DAY, -30, SYSUTCDATETIME())
GROUP BY   c.CityName, at.TypeName, at.Severity
ORDER BY   at.Severity DESC, TotalAlerts DESC;
GO

-- =============================================================================
-- QUERY 6: Recursive CTE — city hierarchy / sensor tree
--          (Demonstrates recursive CTE capability)
-- =============================================================================
WITH SensorHierarchy AS (
    -- Anchor: top-level countries
    SELECT
        co.CountryName      AS Level1,
        NULL                AS Level2,
        NULL                AS Level3,
        NULL                AS Level4,
        0                   AS Depth,
        CAST(co.CountryName AS NVARCHAR(500)) AS Path
    FROM dbo.Country co

    UNION ALL

    -- Level 2: cities
    SELECT
        co.CountryName,
        c.CityName,
        NULL,
        NULL,
        1,
        CAST(co.CountryName + ' > ' + c.CityName AS NVARCHAR(500))
    FROM dbo.City c
    JOIN dbo.Country co ON co.CountryID = c.CountryID

    UNION ALL

    -- Level 3: sensor types per city
    SELECT
        co.CountryName,
        c.CityName,
        st.TypeCode,
        NULL,
        2,
        CAST(co.CountryName + ' > ' + c.CityName + ' > ' + st.TypeCode AS NVARCHAR(500))
    FROM       dbo.Sensor      s
    JOIN       dbo.City        c  ON c.CityID        = s.CityID
    JOIN       dbo.Country     co ON co.CountryID    = c.CountryID
    JOIN       dbo.SensorType  st ON st.SensorTypeID = s.SensorTypeID
    GROUP BY   co.CountryName, c.CityName, st.TypeCode

    UNION ALL

    -- Level 4: individual sensors
    SELECT
        co.CountryName,
        c.CityName,
        st.TypeCode,
        s.SensorCode,
        3,
        CAST(co.CountryName + ' > ' + c.CityName + ' > ' + st.TypeCode + ' > ' + s.SensorCode AS NVARCHAR(500))
    FROM       dbo.Sensor      s
    JOIN       dbo.City        c  ON c.CityID        = s.CityID
    JOIN       dbo.Country     co ON co.CountryID    = c.CountryID
    JOIN       dbo.SensorType  st ON st.SensorTypeID = s.SensorTypeID
    WHERE      s.IsActive = 1
)
SELECT REPLICATE('  ', Depth) + ISNULL(Level4, ISNULL(Level3, ISNULL(Level2, Level1))) AS TreeNode,
       Depth,
       Path
FROM   SensorHierarchy
ORDER BY Path;
GO

-- =============================================================================
-- QUERY 7: JSON output for API consumption
--          Demonstrates: FOR JSON, nested JSON structures
-- =============================================================================
SELECT
    c.CityID,
    c.CityName,
    (
        SELECT
            s.SensorID,
            s.SensorCode,
            st.TypeCode AS SensorType,
            (
                SELECT TOP 1
                    sr.ReadingValue,
                    sr.ReadingAt,
                    sr.IsAnomaly
                FROM dbo.SensorReading sr
                WHERE sr.SensorID = s.SensorID
                ORDER BY sr.ReadingAt DESC
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            ) AS LatestReading
        FROM       dbo.Sensor      s
        JOIN       dbo.SensorType  st ON st.SensorTypeID = s.SensorTypeID
        WHERE      s.CityID   = c.CityID
          AND      s.IsActive = 1
        FOR JSON PATH
    ) AS Sensors
FROM dbo.City c
FOR JSON PATH;
GO

PRINT 'Analytics queries executed successfully.';
GO
