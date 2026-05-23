-- =============================================================================
-- Urban Pulse Analytics — Views
-- Demonstrates: CTEs, Window Functions, Conditional Aggregation,
--               Rolling Averages, PIVOT-like patterns, Ranking
-- =============================================================================

USE UrbanPulseDB;
GO

-- =============================================================================
-- VIEW 1: Real-time sensor status dashboard
-- =============================================================================
CREATE OR ALTER VIEW dbo.vw_SensorStatus
AS
WITH LatestReadings AS (
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
        WHEN lr.ReadingAt IS NULL                                     THEN 'OFFLINE'
        WHEN lr.ReadingAt < DATEADD(MINUTE, -15, SYSUTCDATETIME())    THEN 'STALE'
        WHEN lr.IsAnomaly = 1                                         THEN 'ANOMALY'
        WHEN ua.ActiveAlertCount > 0                                  THEN 'ALERT'
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

    AVG(ha.HourlyAvg) OVER (
        PARTITION BY ha.CityID, ha.SensorTypeID
        ORDER BY ha.HourBucket
        ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
    ) AS Rolling24HrAvg,

    AVG(ha.HourlyAvg) OVER (
        PARTITION BY ha.CityID, ha.SensorTypeID
        ORDER BY ha.HourBucket
        ROWS BETWEEN 167 PRECEDING AND CURRENT ROW
    ) AS Rolling7DayAvg,

    ha.HourlyAvg - LAG(ha.HourlyAvg, 1) OVER (
        PARTITION BY ha.CityID, ha.SensorTypeID
        ORDER BY ha.HourBucket
    ) AS HoH_Delta,

    ha.HourlyAvg - LAG(ha.HourlyAvg, 24) OVER (
        PARTITION BY ha.CityID, ha.SensorTypeID
        ORDER BY ha.HourBucket
    ) AS DoD_Delta,

    PERCENT_RANK() OVER (
        PARTITION BY ha.CityID, ha.SensorTypeID, CAST(ha.HourBucket AS DATE)
        ORDER BY ha.HourlyAvg
    ) AS DailyPercentileRank
FROM       HourlyAgg    ha
JOIN       dbo.City     c  ON c.CityID        = ha.CityID
JOIN       dbo.SensorType st ON st.SensorTypeID = ha.SensorTypeID;
GO

-- =============================================================================
-- VIEW 3: City health scorecard (Refactored for strict grouping and compatibility)
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
        COUNT(*)                                           AS TotalAlerts,
        SUM(CASE WHEN a.IsResolved = 0 THEN 1 ELSE 0 END)  AS OpenAlerts,
        SUM(CASE WHEN a.IsResolved = 1 THEN 1 ELSE 0 END)  AS ResolvedAlerts
    FROM dbo.Alert a
    JOIN dbo.Sensor s ON s.SensorID = a.SensorID
    WHERE a.AlertRaisedAt >= DATEADD(HOUR, -24, SYSUTCDATETIME())
    GROUP BY s.CityID
),
RawMetrics AS (
    SELECT
        c.CityID,
        c.CityName,
        co.CountryName,
        MAX(CASE WHEN st.TypeCode = 'AIR_QUALITY' THEN l.Avg24h END)            AS AirQuality_Avg,
        MAX(CASE WHEN st.TypeCode = 'AIR_QUALITY' THEN l.AnomalyCount END)      AS AirQuality_Anomalies,
        MAX(CASE WHEN st.TypeCode = 'TRAFFIC'     THEN l.Avg24h END)            AS Traffic_Avg,
        MAX(CASE WHEN st.TypeCode = 'TRAFFIC'     THEN l.AnomalyCount END)      AS Traffic_Anomalies,
        MAX(CASE WHEN st.TypeCode = 'NOISE'       THEN l.Avg24h END)            AS Noise_Avg,
        MAX(CASE WHEN st.TypeCode = 'NOISE'       THEN l.AnomalyCount END)      AS Noise_Anomalies,
        ISNULL(ast.TotalAlerts, 0)                                              AS TotalAlerts_24h,
        ISNULL(ast.OpenAlerts, 0)                                               AS OpenAlerts
    FROM       dbo.City         c
    JOIN       dbo.Country      co  ON co.CountryID     = c.CountryID
    LEFT JOIN  Last24h          l   ON l.CityID         = c.CityID
    LEFT JOIN  dbo.SensorType   st  ON st.SensorTypeID  = l.SensorTypeID
    LEFT JOIN  AlertStats       ast ON ast.CityID       = c.CityID
    GROUP BY
        c.CityID, c.CityName, co.CountryName, ast.TotalAlerts, ast.OpenAlerts
),
ScoredMetrics AS (
    SELECT 
        *,
        -- Safe backwards-compatible alternative to GREATEST(0, Score)
        CASE 
            WHEN (100 - (ISNULL(AirQuality_Anomalies, 0) * 5) - (ISNULL(Traffic_Anomalies, 0) * 3) - (ISNULL(Noise_Anomalies, 0) * 2) - (OpenAlerts * 10)) < 0 
            THEN 0
            ELSE (100 - (ISNULL(AirQuality_Anomalies, 0) * 5) - (ISNULL(Traffic_Anomalies, 0) * 3) - (ISNULL(Noise_Anomalies, 0) * 2) - (OpenAlerts * 10))
        END AS HealthScore
    FROM RawMetrics
)
SELECT 
    CityID,
    CityName,
    CountryName,
    AirQuality_Avg,
    AirQuality_Anomalies,
    Traffic_Avg,
    Traffic_Anomalies,
    Noise_Avg,
    Noise_Anomalies,
    TotalAlerts_24h,
    OpenAlerts,
    CAST(HealthScore AS INT) AS HealthScore,
    DENSE_RANK() OVER (ORDER BY HealthScore DESC) AS HealthRank
FROM ScoredMetrics;
GO

-- =============================================================================
-- VIEW 4: Alert response time analysis
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

    CASE
        WHEN a.IsResolved = 1
        THEN DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt)
    END AS ResolutionMinutes,

    CASE
        WHEN a.IsResolved = 0 THEN 'OPEN'
        WHEN DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt) <= 30  THEN 'SLA_MET'
        WHEN DATEDIFF(MINUTE, a.AlertRaisedAt, a.AlertResolvedAt) <= 120 THEN 'SLA_BREACHED_MINOR'
        ELSE 'SLA_BREACHED_MAJOR'
    END AS SlaStatus,

    COUNT(*) OVER (
        PARTITION BY a.SensorID
        ORDER BY a.AlertRaisedAt
        ROWS UNBOUNDED PRECEDING
    ) AS CumulativeAlertCount,

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