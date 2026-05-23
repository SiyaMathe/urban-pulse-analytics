-- =============================================================================
-- Urban Pulse Analytics — Seed Data
-- =============================================================================

USE UrbanPulseDB;
GO

-- Countries
INSERT INTO dbo.Country (CountryCode, CountryName) VALUES
    ('ZA', 'South Africa'),
    ('KE', 'Kenya'),
    ('NG', 'Nigeria'),
    ('EG', 'Egypt'),
    ('MA', 'Morocco');
GO

-- Cities
INSERT INTO dbo.City (CityName, CountryID, Latitude, Longitude, Population) VALUES
    ('Johannesburg', 1, -26.2041,  28.0473,  5635127),
    ('Cape Town',    1, -33.9249,  18.4241,  4618000),
    ('Durban',       1, -29.8587,  31.0218,  3720000),
    ('Nairobi',      2,  -1.2921,  36.8219,  4922000),
    ('Lagos',        3,   6.5244,   3.3792, 15400000);
GO

-- Sensor Types
INSERT INTO dbo.SensorType (TypeCode, TypeDescription, Unit) VALUES
    ('AIR_QUALITY', 'Air Quality Index measurement',        'AQI'),
    ('TRAFFIC',     'Vehicle throughput per hour',          'vehicles/hr'),
    ('NOISE',       'Ambient noise level',                  'dB'),
    ('TEMPERATURE', 'Ambient temperature',                  '°C'),
    ('HUMIDITY',    'Relative humidity',                    '%');
GO

-- Alert Types
INSERT INTO dbo.AlertType (TypeName, Severity, Description) VALUES
    ('ANOMALY_DETECTED',    3, 'Reading deviates > 3 sigma from 24h mean'),
    ('THRESHOLD_BREACH',    4, 'Reading exceeds configured safety threshold'),
    ('SENSOR_OFFLINE',      5, 'No readings received for > 15 minutes'),
    ('DATA_QUALITY',        2, 'Implausible reading detected');
GO

-- Sensors (12 sensors across 3 SA cities)
INSERT INTO dbo.Sensor (SensorCode, SensorTypeID, CityID, LocationDesc, Latitude, Longitude) VALUES
    -- Johannesburg
    ('JHB-AQ-001', 1, 1, 'Sandton CBD',         -26.1076, 28.0567),
    ('JHB-AQ-002', 1, 1, 'Soweto Industrial',   -26.2673, 27.8546),
    ('JHB-TR-001', 2, 1, 'N1 Highway Midrand',  -25.9976, 28.1326),
    ('JHB-NO-001', 3, 1, 'Rosebank Entertainment', -26.1452, 28.0400),
    -- Cape Town
    ('CPT-AQ-001', 1, 2, 'City Bowl',            -33.9258, 18.4232),
    ('CPT-AQ-002', 1, 2, 'Bellville Industrial', -33.9013, 18.6297),
    ('CPT-TR-001', 2, 2, 'N2 Cape Flats',        -34.0052, 18.5694),
    ('CPT-NO-001', 3, 2, 'Long Street',          -33.9252, 18.4183),
    -- Durban
    ('DBN-AQ-001', 1, 3, 'Durban Harbour',       -29.8614, 31.0305),
    ('DBN-TR-001', 2, 3, 'N3 Pinetown',          -29.8170, 30.8573),
    ('DBN-NO-001', 3, 3, 'Florida Road',         -29.8380, 31.0006),
    ('DBN-TM-001', 4, 3, 'Berea Weather Station',-29.8440, 31.0032);
GO

-- Generate realistic sensor readings (last 48 hours, every 15 min per sensor)
-- We use a recursive CTE to generate time series
DECLARE @StartTime DATETIME2 = DATEADD(HOUR, -48, SYSUTCDATETIME());
DECLARE @EndTime   DATETIME2 = SYSUTCDATETIME();

WITH TimeSeries AS (
    SELECT @StartTime AS ReadingTime
    UNION ALL
    SELECT DATEADD(MINUTE, 15, ReadingTime)
    FROM   TimeSeries
    WHERE  ReadingTime < @EndTime
)
INSERT INTO dbo.SensorReading (SensorID, ReadingValue, ReadingAt, IsAnomaly)
SELECT
    s.SensorID,
    -- Simulate realistic values with noise based on sensor type
    CASE s.SensorTypeID
        WHEN 1 THEN -- AQI: 20-150, spikes during rush hour
            ROUND(
                50 + (30 * SIN(DATEDIFF(HOUR, 0, ts.ReadingTime) * 0.26)) +
                (ABS(CHECKSUM(NEWID())) % 30) +
                CASE WHEN DATEPART(HOUR, ts.ReadingTime) BETWEEN 7 AND 9 THEN 40 ELSE 0 END +
                CASE WHEN DATEPART(HOUR, ts.ReadingTime) BETWEEN 17 AND 19 THEN 35 ELSE 0 END,
            1)
        WHEN 2 THEN -- Traffic: 200-2000 vehicles/hr
            ROUND(
                800 + (600 * SIN(DATEDIFF(HOUR, 0, ts.ReadingTime) * 0.26)) +
                (ABS(CHECKSUM(NEWID())) % 200),
            0)
        WHEN 3 THEN -- Noise: 40-90 dB
            ROUND(
                60 + (15 * SIN(DATEDIFF(HOUR, 0, ts.ReadingTime) * 0.26)) +
                (ABS(CHECKSUM(NEWID())) % 15),
            1)
        WHEN 4 THEN -- Temperature: 15-32°C
            ROUND(
                23 + (8 * SIN(DATEDIFF(HOUR, 0, ts.ReadingTime) * 0.26)) +
                (ABS(CHECKSUM(NEWID())) % 4 - 2),
            1)
        ELSE 50
    END AS ReadingValue,
    ts.ReadingTime,
    0 AS IsAnomaly
FROM TimeSeries ts
CROSS JOIN dbo.Sensor s
WHERE s.IsActive = 1
OPTION (MAXRECURSION 500);
GO

-- Insert a few deliberate anomalies
UPDATE dbo.SensorReading
SET IsAnomaly = 1, ReadingValue = ReadingValue * 3
WHERE ReadingID IN (
    SELECT TOP 10 ReadingID
    FROM dbo.SensorReading
    ORDER BY NEWID()
);
GO

-- Seed some alerts
INSERT INTO dbo.Alert (SensorID, AlertTypeID, TriggerValue, ThresholdValue, IsResolved, AlertResolvedAt, Notes)
SELECT
    s.SensorID,
    1,  -- ANOMALY_DETECTED
    250,
    150,
    CASE WHEN ROW_NUMBER() OVER (ORDER BY NEWID()) % 3 = 0 THEN 1 ELSE 0 END,
    CASE WHEN ROW_NUMBER() OVER (ORDER BY NEWID()) % 3 = 0 THEN DATEADD(MINUTE, 45, SYSUTCDATETIME()) ELSE NULL END,
    'Auto-generated during seeding'
FROM dbo.Sensor s
WHERE s.SensorTypeID = 1  -- Air quality sensors only
ORDER BY NEWID();
GO

-- Pre-compute analytics snapshots for last 24 hours
DECLARE @h INT = 0;
WHILE @h < 24
BEGIN
    DECLARE @hour DATETIME2 = DATEADD(HOUR, -@h, DATEADD(HOUR, DATEDIFF(HOUR, 0, SYSUTCDATETIME()), 0));

    DECLARE @cid INT;
    DECLARE @stid INT;

    DECLARE snap_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT CityID, SensorTypeID FROM dbo.Sensor WHERE IsActive = 1;

    OPEN snap_cur;
    FETCH NEXT FROM snap_cur INTO @cid, @stid;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_RefreshAnalyticsSnapshot @CityID = @cid, @SensorTypeID = @stid, @SnapshotHour = @hour;
        FETCH NEXT FROM snap_cur INTO @cid, @stid;
    END
    CLOSE snap_cur;
    DEALLOCATE snap_cur;

    SET @h = @h + 1;
END;
GO

PRINT 'Seed data inserted successfully.';
GO
