-- =============================================================================
-- Urban Pulse Analytics — Views
-- Demonstrates: CTEs, Window Functions, Conditional Aggregation,
--               Rolling Averages, PIVOT-like patterns, Ranking
-- =============================================================================

USE UrbanPulseAnalytics;
GO

-- =============================================================================
-- VIEW 1: Real-time sensor status dashboard
--         Most recent reading per sensor with status classification
-- =============================================================================
CREATE OR ALTER VIEW dbo.vw_SensorStatus
AS
WITH LatestReadings AS (
    -- Window function: get the most recent reading per sensor
    SELECT
        sr.SensorID,
        sr.ReadingValue,
        sr.ReadingAt,
        sr.IsAnomaly,
        ROW_NUMBER() OVER (PARTITION BY sr.SensorID ORDER BY sr.ReadingAt DESC) AS rn
    FROM dbo.SensorReading sr
),
UnresolvedAlerts AS (
    SELECT SensorID, COUNT(*) AS ActiveAlertCount
    FROM   dbo.Alert
    WHERE  IsResolved = 0
    GROUP BY SensorID
)
SELECT
    s.SensorID,
    s.SensorCode,
    c.CityName,
    st.TypeCode             AS SensorType,
    st.Unit,
    lr.ReadingValue         AS LatestValue,
    lr.ReadingAt            AS LastReadingAt,
    lr.IsAnomaly            AS LatestIsAnomaly,
    ISNULL(ua.ActiveAlertCount, 0) AS ActiveAlerts,
    CASE
        WHEN lr.ReadingAt IS NULL                              THEN 'OFFLINE'
        WHEN lr.ReadingAt < DATEADD(MINUTE, -15, SYSUTCDATETIME()) THEN 'STALE'
        WHEN lr.IsAnomaly = 1                                  THEN 'ANOMALY'
        WHEN ua.ActiveAlertCount > 0                           THEN 'ALERT'
        ELSE 'HEALTHY'
    END AS SensorStatus,
    s.IsActive
FROM       dbo.Sensor           s
JOIN       dbo.SensorType       st ON st.SensorTypeID  = s.SensorTypeID
JOIN       dbo.City             c  ON c.CityID          = s.CityID
LEFT JOIN  LatestReadings       lr ON lr.SensorID       = s.SensorID AND lr.rn = 1
LEFT JOIN  UnresolvedAlerts     ua ON ua.SensorID       = s.SensorID;
GO

-- =============================================================================
-- VIEW 2: Hourly trend analysis with rolling 7-day average
--         Demonstrates: LAG, LEAD, window frames (ROWS BETWEEN)
-- =============================================================================
CREATE OR ALTER VIEW dbo.vw_HourlyTrendWithRollingAvg
AS
WITH HourlyAgg AS (
    SELECT
        s.CityID,
        s.SensorTypeID,
        DATEADD(HOUR, DATEDIFF(HOUR, 0, sr.ReadingAt), 0) AS HourBucket,
        AVG(sr.ReadingValue)    AS HourlyAvg,
        MIN(sr.ReadingValue)    AS HourlyMin,
        MAX(sr.ReadingValue)    AS HourlyMax,
        COUNT(*)                AS ReadingCount,
        SUM(CASE WHEN sr.IsAnomaly = 1 THEN 1 ELSE 0 END) AS AnomalyCount
    FROM dbo.SensorReading sr
    JOIN dbo.Sensor s ON s.SensorID = sr.SensorID
    GROUP BY
        s.CityID,
        s.SensorTypeID,
        DATEADD(HOUR, DATEDIFF(HOUR, 0, sr.ReadingAt), 0)
)
SELECT
    ha.CityID,
    c.CityName,
    ha.SensorTypeID,
    st.TypeCode     AS SensorType,
    st.Unit,
    ha.HourBucket,
    ha.HourlyAvg,
    ha.HourlyMin,
    ha.HourlyMax,
    ha.ReadingCount,
    ha.AnomalyCount,

    -- 24-hour rolling average (window function)
    AVG(ha.HourlyAvg) OVER (
        PARTITION BY ha.CityID, ha.SensorTypeID
        ORDER BY ha.HourBucket
        ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
    ) AS Rolling24HrAvg,

    -- 7-day rolling average
    AVG(ha.HourlyAvg) OVER (
        PARTITION BY ha.CityID, ha.SensorTypeID
        ORDER BY ha.HourBucket
        ROWS BETWEEN 167 PRECEDING AND CURRENT ROW
    ) AS Rolling7DayAvg,

    -- Hour-over-hour delta
    ha.HourlyAvg - LAG(ha.HourlyAvg, 1) OVER (
        PARTITION BY ha.CityID, ha.SensorTypeID
        ORDER BY ha.HourBucket
    ) AS HoH_Delta,

    -- Day-over-day comparison (same hour, previous day)
    ha.HourlyAvg - LAG(ha.HourlyAvg, 24) OVER (
        PARTITION BY ha.CityID, ha.SensorTypeID
        ORDER BY ha.HourBucket
    ) AS DoD_Delta,

    -- Percentile rank within day
    PERCENT_RANK() OVER (
        PARTITION BY ha.CityID, ha.SensorTypeID,
                     CAST(ha.HourBucket AS DATE)
        ORDER BY ha.HourlyAvg
    ) AS DailyPercentileRank

FROM       HourlyAgg    ha
JOIN       dbo.City     c  ON c.CityID        = ha.CityID
JOIN       dbo.SensorType st ON st.SensorTypeID = ha.SensorTypeID;
GO

-- =============================================================================
-- VIEW 3: City health scorecard (multi-metric aggregation)
--         Demonstrates: Conditional aggregation, CROSS APPLY, ranking
-- =============================================================================
CREATE OR ALTER VIEW dbo.vw_CityHealthScorecard
AS
WITH Last24h AS (
    SELECT
        s.CityID,
        s.SensorTypeID,
        AVG(sr.ReadingValue)    AS Avg24h,
        COUNT(*)                AS ReadingCount,
        SUM(CASE WHEN sr.IsAnomaly = 1 THEN 1 ELSE 0 END) AS AnomalyCount,
        COUNT(DISTINCT s.SensorID) AS ActiveSensorCount
    FROM dbo.SensorReading sr
    JOIN dbo.Sensor s ON s.SensorID = sr.SensorID
    WHERE sr.ReadingAt >= DATEADD(HOUR, -24, SYSUTCDATETIME())
    GROUP BY s.CityID, s.SensorTypeID
),
AlertStats AS (
    SELECT
        s.CityID,
        COUNT(*)                                            AS TotalAlerts,
        SUM(CASE WHEN a.IsResolved = 0 THEN 1 ELSE 0 END)  AS OpenAlerts,
        SUM(CASE WHEN a.IsResolved = 1 THEN 1 ELSE 0 END)  AS ResolvedAlerts
    FROM dbo.Alert a
    JOIN dbo.Sensor s ON s.SensorID = a.SensorID
    WHERE a.AlertRaisedAt >= DATEADD(HOUR, -24, SYSUTCDATETIME())
    GROUP BY s.CityID
)
SELECT
    c.CityID,
    c.CityName,
    co.CountryName,

    -- Air quality metrics (conditional aggregation)
    MAX(CASE WHEN st.TypeCode = 'AIR_QUALITY' THEN l.Avg24h END)            AS AirQuality_Avg,
    MAX(CASE WHEN st.TypeCode = 'AIR_QUALITY' THEN l.AnomalyCount END)      AS AirQuality_Anomalies,

    -- Traffic metrics
    MAX(CASE WHEN st.TypeCode = 'TRAFFIC'     THEN l.Avg24h END)            AS Traffic_Avg,
    MAX(CASE WHEN st.TypeCode = 'TRAFFIC'     THEN l.AnomalyCount END)      AS Traffic_Anomalies,

    -- Noise metrics
    MAX(CASE WHEN st.TypeCode = 'NOISE'       THEN l.Avg24h END)            AS Noise_Avg,
    MAX(CASE WHEN st.TypeCode = 'NOISE'       THEN l.AnomalyCount END)      AS Noise_Anomalies,

    -- Alert summary
    ISNULL(ast.TotalAlerts, 0)          AS TotalAlerts_24h,
    ISNULL(ast.OpenAlerts, 0)           AS OpenAlerts,

    -- Composite health score (0-100, higher = healthier)
    -- Simple weighted formula: penalise anomalies and open alerts
    CAST(
        GREATEST(0, 100
            - (ISNULL(MAX(CASE WHEN st.TypeCode = 'AIR_QUALITY' THEN l.AnomalyCount END), 0) * 5)
            - (ISNULL(MAX(CASE WHEN st.TypeCode = 'TRAFFIC'     THEN l.AnomalyCount END), 0) * 3)
            - (ISNULL(MAX(CASE WHEN st.TypeCode = 'NOISE'       THEN l.AnomalyCount END), 0) * 2)
            - (ISNULL(ast.OpenAlerts, 0) * 10)
        ) AS INT
    ) AS HealthScore,

    -- Rank cities by health score
    DENSE_RANK() OVER (ORDER BY
        GREATEST(0, 100
            - (ISNULL(MAX(CASE WHEN st.TypeCode = 'AIR_QUALITY' THEN l.AnomalyCount END), 0) * 5)
            - (ISNULL(MAX(CASE WHEN st.TypeCode = 'TRAFFIC'     THEN l.AnomalyCount END), 0) * 3)
            - (ISNULL(MAX(CASE WHEN st.TypeCode = 'NOISE'       THEN l.AnomalyCount END), 0) * 2)
            - (ISNULL(ast.OpenAlerts, 0) * 10)
        ) DESC
    ) AS HealthRank

FROM       dbo.City         c
JOIN       dbo.Country      co  ON co.CountryID     = c.CountryID
LEFT JOIN  Last24h          l   ON l.CityID         = c.CityID
LEFT JOIN  dbo.SensorType   st  ON st.SensorTypeID  = l.SensorTypeID
LEFT JOIN  AlertStats       ast ON ast.CityID       = c.CityID
GROUP BY
    c.CityID,
    c.CityName,
    co.CountryName,
    ast.TotalAlerts,
    ast.OpenAlerts,
    ast.ResolvedAlerts;
GO

-- =============================================================================
-- VIEW 4: Alert response time analysis
--         Demonstrates: DATEDIFF, window functions, SLA analysis
-- =============================================================================
CREATE OR ALTER VIEW dbo.vw_AlertResponseAnalysis
AS
SELECT
    a.AlertID,
    s.SensorCode,
    c.CityName,
    at.TypeName         AS AlertType,
    at.Severity,
    a.TriggerValue,
    a.ThresholdValue,
    a.AlertRaisedAt,
    a.AlertResolvedAt,
    a.IsResolved,

    -- Response time in minutes
    CASE
        WHEN a.IsResolved = 1
        THEN DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt)
    END AS ResolutionMinutes,

    -- SLA classification
    CASE
        WHEN a.IsResolved = 0 THEN 'OPEN'
        WHEN DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt) <= 30  THEN 'SLA_MET'
        WHEN DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt) <= 120 THEN 'SLA_BREACHED_MINOR'
        ELSE 'SLA_BREACHED_MAJOR'
    END AS SlaStatus,

    -- Running count of alerts per sensor (cumulative)
    COUNT(*) OVER (
        PARTITION BY a.SensorID
        ORDER BY a.AlertRaisedAt
        ROWS UNBOUNDED PRECEDING
    ) AS CumulativeAlertCount,

    -- Average resolution time for same alert type (benchmark)
    AVG(CAST(DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt) AS FLOAT)) OVER (
        PARTITION BY a.AlertTypeID
    ) AS AvgResolutionMinutes_ByType

FROM       dbo.Alert        a
JOIN       dbo.Sensor       s  ON s.SensorID     = a.SensorID
JOIN       dbo.City         c  ON c.CityID        = s.CityID
JOIN       dbo.AlertType    at ON at.AlertTypeID  = a.AlertTypeID;
GO

PRINT 'Views created successfully.';
GO
