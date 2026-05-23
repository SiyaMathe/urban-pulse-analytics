USE UrbanPulseDB;
GO

-- Re-run only the pre-compute analytics snapshots loop
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

PRINT 'Analytics pre-compute snapshots generated successfully!';
GO