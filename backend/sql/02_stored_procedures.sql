-- =============================================================================
-- Urban Pulse Analytics — Stored Procedures
-- Demonstrates: Transactions, Error Handling, Dynamic SQL, Output Parameters,
--               Upsert (MERGE), Pagination, Parameter Validation
-- =============================================================================

USE UrbanPulseAnalytics;
GO

-- =============================================================================
-- SP 1: Ingest a sensor reading with anomaly detection
--        Raises an alert automatically if value exceeds threshold
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_IngestSensorReading
    @SensorCode         VARCHAR(50),
    @ReadingValue       DECIMAL(18,4),
    @RawPayload         NVARCHAR(MAX)   = NULL,
    @AnomalyThreshold   DECIMAL(18,4)   = NULL,     -- optional override
    @ReadingID          BIGINT          OUTPUT,
    @AlertRaised        BIT             OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SensorID       INT;
    DECLARE @SensorTypeID   INT;
    DECLARE @CityID         INT;
    DECLARE @IsAnomaly      BIT = 0;
    DECLARE @DefaultThreshold DECIMAL(18,4);

    -- ── Validate sensor exists and is active ──────────────────────────────────
    SELECT
        @SensorID       = s.SensorID,
        @SensorTypeID   = s.SensorTypeID,
        @CityID         = s.CityID
    FROM dbo.Sensor s
    WHERE s.SensorCode = @SensorCode
      AND s.IsActive   = 1;

    IF @SensorID IS NULL
    BEGIN
        RAISERROR('Sensor ''%s'' not found or inactive.', 16, 1, @SensorCode);
        RETURN;
    END

    -- ── Anomaly detection (simple Z-score approximation using recent stddev) ──
    DECLARE @RecentAvg  DECIMAL(18,4);
    DECLARE @RecentStd  DECIMAL(18,4);

    SELECT
        @RecentAvg = AVG(ReadingValue),
        @RecentStd = STDEV(ReadingValue)
    FROM dbo.SensorReading
    WHERE SensorID  = @SensorID
      AND ReadingAt >= DATEADD(HOUR, -24, SYSUTCDATETIME());

    -- Flag anomaly if > 3 standard deviations from 24h mean
    IF @RecentStd IS NOT NULL AND @RecentStd > 0
    BEGIN
        IF ABS(@ReadingValue - @RecentAvg) > (3 * @RecentStd)
            SET @IsAnomaly = 1;
    END

    BEGIN TRANSACTION;
    BEGIN TRY

        -- ── Insert the reading ────────────────────────────────────────────────
        INSERT INTO dbo.SensorReading (SensorID, ReadingValue, RawPayload, IsAnomaly)
        VALUES (@SensorID, @ReadingValue, @RawPayload, @IsAnomaly);

        SET @ReadingID = SCOPE_IDENTITY();

        -- ── Raise alert if anomaly detected ───────────────────────────────────
        SET @AlertRaised = 0;
        IF @IsAnomaly = 1
        BEGIN
            DECLARE @AlertTypeID INT;
            SELECT TOP 1 @AlertTypeID = AlertTypeID
            FROM dbo.AlertType
            WHERE TypeName = 'ANOMALY_DETECTED';

            IF @AlertTypeID IS NOT NULL
            BEGIN
                INSERT INTO dbo.Alert (SensorID, AlertTypeID, TriggerValue, ThresholdValue)
                VALUES (@SensorID, @AlertTypeID, @ReadingValue, ISNULL(@AnomalyThreshold, @RecentAvg + 3 * @RecentStd));

                SET @AlertRaised = 1;
            END
        END

        -- ── Update sensor's UpdatedAt timestamp ───────────────────────────────
        UPDATE dbo.Sensor
        SET UpdatedAt = SYSUTCDATETIME()
        WHERE SensorID = @SensorID;

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @ErrMsg     NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSeverity INT           = ERROR_SEVERITY();
        DECLARE @ErrState    INT           = ERROR_STATE();

        RAISERROR(@ErrMsg, @ErrSeverity, @ErrState);
    END CATCH
END;
GO

-- =============================================================================
-- SP 2: MERGE-based snapshot upsert (idempotent — safe to re-run)
--        Computes the Gold-layer hourly rollup for a city+type combination
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnalyticsSnapshot
    @CityID         INT,
    @SensorTypeID   INT,
    @SnapshotHour   DATETIME2   -- must be truncated to the hour
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Truncate to hour boundary (caller responsibility but we enforce it)
    DECLARE @HourBoundary DATETIME2 =
        DATEADD(HOUR, DATEDIFF(HOUR, 0, @SnapshotHour), 0);

    DECLARE @HourEnd DATETIME2 = DATEADD(HOUR, 1, @HourBoundary);

    BEGIN TRANSACTION;
    BEGIN TRY

        MERGE dbo.AnalyticsSnapshot AS target
        USING (
            SELECT
                @CityID                     AS CityID,
                @SensorTypeID               AS SensorTypeID,
                @HourBoundary               AS SnapshotHour,
                AVG(sr.ReadingValue)        AS AvgValue,
                MIN(sr.ReadingValue)        AS MinValue,
                MAX(sr.ReadingValue)        AS MaxValue,
                COUNT(sr.ReadingID)         AS ReadingCount,
                SUM(CASE WHEN sr.IsAnomaly = 1 THEN 1 ELSE 0 END) AS AlertCount
            FROM dbo.SensorReading  sr
            JOIN dbo.Sensor         s ON s.SensorID     = sr.SensorID
            WHERE s.CityID          = @CityID
              AND s.SensorTypeID    = @SensorTypeID
              AND sr.ReadingAt      >= @HourBoundary
              AND sr.ReadingAt      <  @HourEnd
        ) AS source
        ON  target.CityID       = source.CityID
        AND target.SensorTypeID = source.SensorTypeID
        AND target.SnapshotHour = source.SnapshotHour

        WHEN MATCHED THEN
            UPDATE SET
                AvgValue        = source.AvgValue,
                MinValue        = source.MinValue,
                MaxValue        = source.MaxValue,
                ReadingCount    = source.ReadingCount,
                AlertCount      = source.AlertCount,
                ComputedAt      = SYSUTCDATETIME()

        WHEN NOT MATCHED BY TARGET THEN
            INSERT (CityID, SensorTypeID, SnapshotHour, AvgValue, MinValue, MaxValue, ReadingCount, AlertCount)
            VALUES (source.CityID, source.SensorTypeID, source.SnapshotHour,
                    source.AvgValue, source.MinValue, source.MaxValue,
                    source.ReadingCount, source.AlertCount);

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- =============================================================================
-- SP 3: Paginated sensor readings with optional filters (dynamic SQL)
--        Demonstrates: dynamic SQL with parameterized inputs (no SQL injection)
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetSensorReadings
    @CityID         INT             = NULL,
    @SensorTypeCode VARCHAR(50)     = NULL,
    @FromDate       DATETIME2       = NULL,
    @ToDate         DATETIME2       = NULL,
    @AnomaliesOnly  BIT             = 0,
    @PageNumber     INT             = 1,
    @PageSize       INT             = 50,
    @TotalCount     INT             OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Parameter validation
    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   < 1 SET @PageSize   = 10;
    IF @PageSize   > 1000 SET @PageSize = 1000;

    -- Build dynamic WHERE clause safely using sp_executesql parameters
    DECLARE @sql        NVARCHAR(MAX);
    DECLARE @countSql   NVARCHAR(MAX);
    DECLARE @params     NVARCHAR(MAX);

    SET @params = N'@CityID INT, @SensorTypeCode VARCHAR(50), @FromDate DATETIME2,
                    @ToDate DATETIME2, @AnomaliesOnly BIT,
                    @PageNumber INT, @PageSize INT, @TotalCount INT OUTPUT';

    SET @countSql = N'
        SELECT @TotalCount = COUNT(*)
        FROM   dbo.SensorReading sr
        JOIN   dbo.Sensor        s  ON s.SensorID     = sr.SensorID
        JOIN   dbo.SensorType    st ON st.SensorTypeID = s.SensorTypeID
        JOIN   dbo.City          c  ON c.CityID        = s.CityID
        WHERE  1 = 1
        ' + CASE WHEN @CityID         IS NOT NULL THEN N' AND c.CityID     = @CityID'         ELSE N'' END
          + CASE WHEN @SensorTypeCode IS NOT NULL THEN N' AND st.TypeCode  = @SensorTypeCode'  ELSE N'' END
          + CASE WHEN @FromDate       IS NOT NULL THEN N' AND sr.ReadingAt >= @FromDate'        ELSE N'' END
          + CASE WHEN @ToDate         IS NOT NULL THEN N' AND sr.ReadingAt <= @ToDate'          ELSE N'' END
          + CASE WHEN @AnomaliesOnly  = 1         THEN N' AND sr.IsAnomaly = 1'                 ELSE N'' END;

    EXEC sp_executesql @countSql, @params,
        @CityID, @SensorTypeCode, @FromDate, @ToDate, @AnomaliesOnly,
        1, 50, @TotalCount OUTPUT;

    SET @sql = N'
        SELECT
            sr.ReadingID,
            s.SensorCode,
            c.CityName,
            st.TypeCode         AS SensorType,
            st.Unit,
            sr.ReadingValue,
            sr.ReadingAt,
            sr.IsAnomaly,
            sr.RawPayload
        FROM   dbo.SensorReading sr
        JOIN   dbo.Sensor        s  ON s.SensorID      = sr.SensorID
        JOIN   dbo.SensorType    st ON st.SensorTypeID  = s.SensorTypeID
        JOIN   dbo.City          c  ON c.CityID         = s.CityID
        WHERE  1 = 1
        ' + CASE WHEN @CityID         IS NOT NULL THEN N' AND c.CityID     = @CityID'         ELSE N'' END
          + CASE WHEN @SensorTypeCode IS NOT NULL THEN N' AND st.TypeCode  = @SensorTypeCode'  ELSE N'' END
          + CASE WHEN @FromDate       IS NOT NULL THEN N' AND sr.ReadingAt >= @FromDate'        ELSE N'' END
          + CASE WHEN @ToDate         IS NOT NULL THEN N' AND sr.ReadingAt <= @ToDate'          ELSE N'' END
          + CASE WHEN @AnomaliesOnly  = 1         THEN N' AND sr.IsAnomaly = 1'                 ELSE N'' END
          + N' ORDER BY sr.ReadingAt DESC
             OFFSET (@PageNumber - 1) * @PageSize ROWS
             FETCH NEXT @PageSize ROWS ONLY;';

    EXEC sp_executesql @sql, @params,
        @CityID, @SensorTypeCode, @FromDate, @ToDate, @AnomaliesOnly,
        @PageNumber, @PageSize, @TotalCount OUTPUT;
END;
GO

-- =============================================================================
-- SP 4: Resolve an alert with audit trail
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_ResolveAlert
    @AlertID    INT,
    @Notes      NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.Alert WHERE AlertID = @AlertID AND IsResolved = 0)
    BEGIN
        RAISERROR('Alert %d does not exist or is already resolved.', 16, 1, @AlertID);
        RETURN;
    END

    UPDATE dbo.Alert
    SET
        IsResolved      = 1,
        AlertResolvedAt = SYSUTCDATETIME(),
        Notes           = ISNULL(@Notes, Notes)
    WHERE AlertID = @AlertID;

    SELECT
        a.AlertID,
        a.IsResolved,
        a.AlertResolvedAt,
        s.SensorCode,
        at.TypeName     AS AlertType
    FROM dbo.Alert     a
    JOIN dbo.Sensor    s  ON s.SensorID    = a.SensorID
    JOIN dbo.AlertType at ON at.AlertTypeID = a.AlertTypeID
    WHERE a.AlertID = @AlertID;
END;
GO

-- =============================================================================
-- SP 5: Bulk ingest from JSON (simulates Event Hub / queue message processing)
--        Demonstrates: OPENJSON, bulk insert, error-tolerant row-by-row commit
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_BulkIngestFromJson
    @JsonPayload    NVARCHAR(MAX),
    @SuccessCount   INT OUTPUT,
    @FailureCount   INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @SuccessCount = 0;
    SET @FailureCount = 0;

    -- Parse JSON array of readings
    DECLARE @Readings TABLE (
        SensorCode      VARCHAR(50),
        ReadingValue    DECIMAL(18,4),
        ReadingAt       DATETIME2,
        RawPayload      NVARCHAR(MAX)
    );

    INSERT INTO @Readings (SensorCode, ReadingValue, ReadingAt, RawPayload)
    SELECT
        j.SensorCode,
        TRY_CAST(j.ReadingValue AS DECIMAL(18,4)),
        TRY_CAST(j.ReadingAt   AS DATETIME2),
        j.[value]
    FROM OPENJSON(@JsonPayload) WITH (
        SensorCode      VARCHAR(50)     '$.sensor_code',
        ReadingValue    NVARCHAR(50)    '$.value',
        ReadingAt       NVARCHAR(50)    '$.timestamp'
    ) j;

    -- Process each row individually (tolerate individual failures)
    DECLARE @SensorCode     VARCHAR(50);
    DECLARE @ReadingValue   DECIMAL(18,4);
    DECLARE @ReadingAt      DATETIME2;
    DECLARE @RawPayload     NVARCHAR(MAX);
    DECLARE @ReadingID      BIGINT;
    DECLARE @AlertRaised    BIT;

    DECLARE reading_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT SensorCode, ReadingValue, ReadingAt, RawPayload
        FROM   @Readings
        WHERE  SensorCode IS NOT NULL AND ReadingValue IS NOT NULL;

    OPEN reading_cursor;
    FETCH NEXT FROM reading_cursor INTO @SensorCode, @ReadingValue, @ReadingAt, @RawPayload;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC dbo.usp_IngestSensorReading
                @SensorCode     = @SensorCode,
                @ReadingValue   = @ReadingValue,
                @RawPayload     = @RawPayload,
                @ReadingID      = @ReadingID OUTPUT,
                @AlertRaised    = @AlertRaised OUTPUT;

            SET @SuccessCount = @SuccessCount + 1;
        END TRY
        BEGIN CATCH
            SET @FailureCount = @FailureCount + 1;
            -- Log failure (in production, write to an error log table)
        END CATCH

        FETCH NEXT FROM reading_cursor INTO @SensorCode, @ReadingValue, @ReadingAt, @RawPayload;
    END

    CLOSE reading_cursor;
    DEALLOCATE reading_cursor;
END;
GO

PRINT 'Stored procedures created successfully.';
GO
