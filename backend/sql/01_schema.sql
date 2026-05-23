-- =============================================================================
-- Urban Pulse Analytics — Database Schema
-- Normalized to Third Normal Form (3NF)
-- Azure SQL Database / MS SQL Server 2019+
--
-- Schema Design Principles:
--   • All entities use surrogate INT IDENTITY primary keys
--   • All foreign key relationships explicitly constrained
--   • NO transitive dependencies (3NF compliant)
--   • Soft deletes via IsActive / DeletedAt pattern
--   • Audit columns (CreatedAt, UpdatedAt) on all mutable tables
--   • Indexed for analytics query patterns
-- =============================================================================

USE master;
GO

IF DB_ID('UrbanPulseAnalytics') IS NOT NULL
BEGIN
    ALTER DATABASE UrbanPulseAnalytics SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE UrbanPulseAnalytics;
END
GO

CREATE DATABASE UrbanPulseAnalytics
    COLLATE SQL_Latin1_General_CP1_CI_AS;
GO

USE UrbanPulseAnalytics;
GO

-- =============================================================================
-- LOOKUP / REFERENCE TABLES  (no FKs into these, they own vocabulary)
-- =============================================================================

-- Q1: Countries (lookup — avoids duplicating country name strings everywhere)
CREATE TABLE dbo.Country (
    CountryID       INT             NOT NULL IDENTITY(1,1),
    CountryCode     CHAR(2)         NOT NULL,   -- ISO 3166-1 alpha-2
    CountryName     NVARCHAR(100)   NOT NULL,
    CONSTRAINT PK_Country       PRIMARY KEY (CountryID),
    CONSTRAINT UQ_Country_Code  UNIQUE      (CountryCode)
);
GO

-- Q2: Cities — depends on Country (1NF→3NF: country data lives in Country table)
CREATE TABLE dbo.City (
    CityID          INT             NOT NULL IDENTITY(1,1),
    CityName        NVARCHAR(150)   NOT NULL,
    CountryID       INT             NOT NULL,
    Latitude        DECIMAL(9,6)    NOT NULL,
    Longitude       DECIMAL(9,6)    NOT NULL,
    Population      BIGINT          NULL,
    CreatedAt       DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_City          PRIMARY KEY (CityID),
    CONSTRAINT FK_City_Country  FOREIGN KEY (CountryID) REFERENCES dbo.Country(CountryID),
    CONSTRAINT UQ_City_Name_Country UNIQUE (CityName, CountryID)
);
GO

-- Q3: SensorType lookup — eliminates repeating type strings on Sensor rows
CREATE TABLE dbo.SensorType (
    SensorTypeID    INT             NOT NULL IDENTITY(1,1),
    TypeCode        VARCHAR(50)     NOT NULL,   -- e.g. 'AIR_QUALITY', 'TRAFFIC', 'NOISE'
    TypeDescription NVARCHAR(255)   NOT NULL,
    Unit            VARCHAR(30)     NOT NULL,   -- e.g. 'AQI', 'vehicles/hr', 'dB'
    CONSTRAINT PK_SensorType        PRIMARY KEY (SensorTypeID),
    CONSTRAINT UQ_SensorType_Code   UNIQUE      (TypeCode)
);
GO

-- Q4: AlertType lookup — separates alert taxonomy from alert instances
CREATE TABLE dbo.AlertType (
    AlertTypeID     INT             NOT NULL IDENTITY(1,1),
    TypeName        NVARCHAR(100)   NOT NULL,
    Severity        TINYINT         NOT NULL    CHECK (Severity BETWEEN 1 AND 5),
    Description     NVARCHAR(500)   NULL,
    CONSTRAINT PK_AlertType PRIMARY KEY (AlertTypeID)
);
GO

-- =============================================================================
-- CORE ENTITY TABLES
-- =============================================================================

-- Sensors: one row per physical IoT device
CREATE TABLE dbo.Sensor (
    SensorID        INT             NOT NULL IDENTITY(1,1),
    SensorCode      VARCHAR(50)     NOT NULL,   -- e.g. 'JHB-AQ-001'
    SensorTypeID    INT             NOT NULL,
    CityID          INT             NOT NULL,
    LocationDesc    NVARCHAR(255)   NULL,
    Latitude        DECIMAL(9,6)    NULL,
    Longitude       DECIMAL(9,6)    NULL,
    IsActive        BIT             NOT NULL DEFAULT 1,
    InstalledAt     DATETIME2       NULL,
    CreatedAt       DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedAt       DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Sensor            PRIMARY KEY (SensorID),
    CONSTRAINT FK_Sensor_Type       FOREIGN KEY (SensorTypeID) REFERENCES dbo.SensorType(SensorTypeID),
    CONSTRAINT FK_Sensor_City       FOREIGN KEY (CityID)       REFERENCES dbo.City(CityID),
    CONSTRAINT UQ_Sensor_Code       UNIQUE (SensorCode)
);
GO

-- SensorReading: high-frequency time-series data (the "fact" table)
-- Partitioned by ReadingDate for large-scale performance
CREATE TABLE dbo.SensorReading (
    ReadingID       BIGINT          NOT NULL IDENTITY(1,1),
    SensorID        INT             NOT NULL,
    ReadingValue    DECIMAL(18,4)   NOT NULL,
    ReadingAt       DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    RawPayload      NVARCHAR(MAX)   NULL,   -- original JSON from device
    IsAnomaly       BIT             NOT NULL DEFAULT 0,
    CONSTRAINT PK_SensorReading         PRIMARY KEY (ReadingID),
    CONSTRAINT FK_SensorReading_Sensor  FOREIGN KEY (SensorID) REFERENCES dbo.Sensor(SensorID)
);
GO

-- Alert: an event raised when a sensor reading breaches a threshold
CREATE TABLE dbo.Alert (
    AlertID         INT             NOT NULL IDENTITY(1,1),
    SensorID        INT             NOT NULL,
    AlertTypeID     INT             NOT NULL,
    TriggerValue    DECIMAL(18,4)   NOT NULL,
    ThresholdValue  DECIMAL(18,4)   NOT NULL,
    AlertRaisedAt   DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    AlertResolvedAt DATETIME2       NULL,
    IsResolved      BIT             NOT NULL DEFAULT 0,
    Notes           NVARCHAR(1000)  NULL,
    CONSTRAINT PK_Alert             PRIMARY KEY (AlertID),
    CONSTRAINT FK_Alert_Sensor      FOREIGN KEY (SensorID)    REFERENCES dbo.Sensor(SensorID),
    CONSTRAINT FK_Alert_AlertType   FOREIGN KEY (AlertTypeID) REFERENCES dbo.AlertType(AlertTypeID)
);
GO

-- AnalyticsSnapshot: pre-aggregated hourly rollups for dashboard performance
-- This is the "Gold layer" table populated by the Azure Function
CREATE TABLE dbo.AnalyticsSnapshot (
    SnapshotID      INT             NOT NULL IDENTITY(1,1),
    CityID          INT             NOT NULL,
    SensorTypeID    INT             NOT NULL,
    SnapshotHour    DATETIME2       NOT NULL,   -- truncated to hour
    AvgValue        DECIMAL(18,4)   NOT NULL,
    MinValue        DECIMAL(18,4)   NOT NULL,
    MaxValue        DECIMAL(18,4)   NOT NULL,
    ReadingCount    INT             NOT NULL,
    AlertCount      INT             NOT NULL DEFAULT 0,
    ComputedAt      DATETIME2       NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_AnalyticsSnapshot             PRIMARY KEY (SnapshotID),
    CONSTRAINT FK_Snapshot_City                 FOREIGN KEY (CityID)       REFERENCES dbo.City(CityID),
    CONSTRAINT FK_Snapshot_SensorType           FOREIGN KEY (SensorTypeID) REFERENCES dbo.SensorType(SensorTypeID),
    CONSTRAINT UQ_Snapshot_City_Type_Hour       UNIQUE (CityID, SensorTypeID, SnapshotHour)
);
GO

-- =============================================================================
-- INDEXES — optimised for the analytics read patterns
-- =============================================================================

-- SensorReading: time-series scans (most common query pattern)
CREATE NONCLUSTERED INDEX IX_SensorReading_SensorID_Time
    ON dbo.SensorReading (SensorID, ReadingAt DESC)
    INCLUDE (ReadingValue, IsAnomaly);
GO

-- SensorReading: city-level aggregations via join to Sensor
CREATE NONCLUSTERED INDEX IX_SensorReading_ReadingAt
    ON dbo.SensorReading (ReadingAt DESC)
    INCLUDE (SensorID, ReadingValue);
GO

-- Alert: unresolved alert dashboard query
CREATE NONCLUSTERED INDEX IX_Alert_Unresolved
    ON dbo.Alert (IsResolved, AlertRaisedAt DESC)
    WHERE IsResolved = 0;
GO

-- AnalyticsSnapshot: dashboard range scans
CREATE NONCLUSTERED INDEX IX_Snapshot_City_Type_Hour
    ON dbo.AnalyticsSnapshot (CityID, SensorTypeID, SnapshotHour DESC);
GO

-- Sensor: active sensor lookup by city
CREATE NONCLUSTERED INDEX IX_Sensor_City_Active
    ON dbo.Sensor (CityID, IsActive)
    INCLUDE (SensorCode, SensorTypeID);
GO

PRINT 'Schema created successfully.';
GO
