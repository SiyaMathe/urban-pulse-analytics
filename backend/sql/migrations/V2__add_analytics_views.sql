-- =============================================================================
-- Migration V2: Add Analytics Views + Performance Enhancements
-- =============================================================================

USE UrbanPulseAnalytics;
GO

IF EXISTS (SELECT 1 FROM dbo._MigrationHistory WHERE ScriptName = 'V2__add_analytics_views')
BEGIN
    PRINT 'Migration V2 already applied. Skipping.';
    RETURN;
END
GO

-- Add computed column for fast hour-of-day queries on SensorReading
ALTER TABLE dbo.SensorReading
    ADD ReadingHour AS DATEPART(HOUR, ReadingAt) PERSISTED;
GO

-- Index on computed column for heatmap queries
CREATE NONCLUSTERED INDEX IX_SensorReading_Hour_SensorID
    ON dbo.SensorReading (ReadingHour, SensorID)
    INCLUDE (ReadingValue, IsAnomaly);
GO

-- Add a fast lookup for sensor code → SensorID (used by ingest path)
CREATE NONCLUSTERED INDEX IX_Sensor_SensorCode_Active
    ON dbo.Sensor (SensorCode)
    INCLUDE (SensorID, SensorTypeID, CityID)
    WHERE IsActive = 1;
GO

-- Materialised-style table for city daily summaries (refreshed by Function)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CityDailySummary')
BEGIN
    CREATE TABLE dbo.CityDailySummary (
        SummaryID       INT             NOT NULL IDENTITY(1,1),
        CityID          INT             NOT NULL,
        SummaryDate     DATE            NOT NULL,
        SensorTypeID    INT             NOT NULL,
        AvgValue        DECIMAL(18,4)   NULL,
        MinValue        DECIMAL(18,4)   NULL,
        MaxValue        DECIMAL(18,4)   NULL,
        TotalReadings   INT             NOT NULL DEFAULT 0,
        TotalAnomalies  INT             NOT NULL DEFAULT 0,
        HealthScore     TINYINT         NULL,
        ComputedAt      DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_CityDailySummary          PRIMARY KEY (SummaryID),
        CONSTRAINT FK_CDS_City                  FOREIGN KEY (CityID)       REFERENCES dbo.City(CityID),
        CONSTRAINT FK_CDS_SensorType            FOREIGN KEY (SensorTypeID) REFERENCES dbo.SensorType(SensorTypeID),
        CONSTRAINT UQ_CDS_City_Date_Type        UNIQUE (CityID, SummaryDate, SensorTypeID)
    );
    PRINT 'Created CityDailySummary table.';
END
GO

-- Stored procedure to refresh daily summary (idempotent MERGE)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCityDailySummary
    @CityID     INT,
    @SummaryDate DATE = NULL   -- defaults to yesterday
AS
BEGIN
    SET NOCOUNT ON;
    IF @SummaryDate IS NULL SET @SummaryDate = CAST(DATEADD(DAY, -1, SYSUTCDATETIME()) AS DATE);

    DECLARE @DayStart DATETIME2 = CAST(@SummaryDate AS DATETIME2);
    DECLARE @DayEnd   DATETIME2 = DATEADD(DAY, 1, @DayStart);

    MERGE dbo.CityDailySummary AS target
    USING (
        SELECT
            @CityID             AS CityID,
            @SummaryDate        AS SummaryDate,
            s.SensorTypeID,
            AVG(sr.ReadingValue) AS AvgValue,
            MIN(sr.ReadingValue) AS MinValue,
            MAX(sr.ReadingValue) AS MaxValue,
            COUNT(*)             AS TotalReadings,
            SUM(CASE WHEN sr.IsAnomaly = 1 THEN 1 ELSE 0 END) AS TotalAnomalies
        FROM dbo.SensorReading sr
        JOIN dbo.Sensor s ON s.SensorID = sr.SensorID
        WHERE s.CityID      = @CityID
          AND sr.ReadingAt  >= @DayStart
          AND sr.ReadingAt  <  @DayEnd
        GROUP BY s.SensorTypeID
    ) AS source
    ON  target.CityID       = source.CityID
    AND target.SummaryDate  = source.SummaryDate
    AND target.SensorTypeID = source.SensorTypeID

    WHEN MATCHED THEN UPDATE SET
        AvgValue       = source.AvgValue,
        MinValue       = source.MinValue,
        MaxValue       = source.MaxValue,
        TotalReadings  = source.TotalReadings,
        TotalAnomalies = source.TotalAnomalies,
        ComputedAt     = SYSUTCDATETIME()

    WHEN NOT MATCHED THEN INSERT
        (CityID, SummaryDate, SensorTypeID, AvgValue, MinValue, MaxValue, TotalReadings, TotalAnomalies)
    VALUES
        (source.CityID, source.SummaryDate, source.SensorTypeID,
         source.AvgValue, source.MinValue, source.MaxValue,
         source.TotalReadings, source.TotalAnomalies);
END;
GO

-- Record migration
INSERT INTO dbo._MigrationHistory (ScriptName) VALUES ('V2__add_analytics_views');
PRINT 'Migration V2 applied successfully.';
GO
