-- =============================================================================
-- Migration V1: Initial Schema
-- Idempotent — safe to re-run (checks existence before creating)
-- =============================================================================

USE UrbanPulseAnalytics;
GO

-- Track applied migrations
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = '_MigrationHistory')
BEGIN
    CREATE TABLE dbo._MigrationHistory (
        MigrationID     INT             NOT NULL IDENTITY(1,1),
        ScriptName      NVARCHAR(255)   NOT NULL,
        AppliedAt       DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
        Checksum        NVARCHAR(64)    NULL,
        CONSTRAINT PK_MigrationHistory  PRIMARY KEY (MigrationID),
        CONSTRAINT UQ_MigrationHistory  UNIQUE (ScriptName)
    );
    PRINT 'Created _MigrationHistory table.';
END
GO

-- Skip if already applied
IF EXISTS (SELECT 1 FROM dbo._MigrationHistory WHERE ScriptName = 'V1__initial_schema')
BEGIN
    PRINT 'Migration V1 already applied. Skipping.';
    RETURN;
END
GO

-- Run the schema
:r ../01_schema.sql
:r ../02_stored_procedures.sql
:r ../03_views.sql

-- Record migration
INSERT INTO dbo._MigrationHistory (ScriptName) VALUES ('V1__initial_schema');
PRINT 'Migration V1 applied successfully.';
GO
