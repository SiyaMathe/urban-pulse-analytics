using System;
using System.Text.Json;
using System.Threading.Tasks;
using Azure.Messaging.EventHubs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace UrbanPulse.Functions;

/// <summary>
/// Queue-triggered Azure Function that ingests sensor reading messages
/// from Azure Storage Queue into the Azure SQL Database.
///
/// Message format (JSON):
/// {
///   "sensor_code": "JHB-AQ-001",
///   "value": 87.4,
///   "timestamp": "2024-01-15T08:30:00Z",
///   "raw_payload": "..."
/// }
/// </summary>
public class QueueIngestFunction
{
    private readonly ILogger<QueueIngestFunction> _logger;
    private readonly string _connectionString;

    public QueueIngestFunction(ILogger<QueueIngestFunction> logger)
    {
        _logger = logger;
        _connectionString = Environment.GetEnvironmentVariable("AZURE_SQL_CONNECTION_STRING")
            ?? throw new InvalidOperationException("AZURE_SQL_CONNECTION_STRING not configured");
    }

    [Function("QueueIngestFunction")]
    public async Task Run(
        [QueueTrigger("sensor-readings-queue", Connection = "AZURE_STORAGE_CONNECTION_STRING")]
        string messageBody,
        FunctionContext context)
    {
        _logger.LogInformation("Processing queue message at {Time}", DateTimeOffset.UtcNow);

        SensorReadingMessage? message;
        try
        {
            message = JsonSerializer.Deserialize<SensorReadingMessage>(messageBody,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

            if (message is null || string.IsNullOrWhiteSpace(message.SensorCode))
            {
                _logger.LogWarning("Invalid message format. Message: {Body}", messageBody);
                return;
            }
        }
        catch (JsonException ex)
        {
            _logger.LogError(ex, "Failed to deserialize message: {Body}", messageBody);
            throw; // Re-throw so Azure retries / dead-letters
        }

        await IngestReadingAsync(message, messageBody);
    }

    /// <summary>
    /// Calls the stored procedure usp_IngestSensorReading for clean separation of SQL logic
    /// </summary>
    private async Task IngestReadingAsync(SensorReadingMessage message, string rawPayload)
    {
        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync();

        await using var cmd = new SqlCommand("dbo.usp_IngestSensorReading", connection)
        {
            CommandType = System.Data.CommandType.StoredProcedure,
            CommandTimeout = 30
        };

        cmd.Parameters.AddWithValue("@SensorCode",  message.SensorCode);
        cmd.Parameters.AddWithValue("@ReadingValue", message.Value);
        cmd.Parameters.AddWithValue("@RawPayload",   rawPayload);

        var readingIdParam = cmd.Parameters.Add("@ReadingID", System.Data.SqlDbType.BigInt);
        readingIdParam.Direction = System.Data.ParameterDirection.Output;

        var alertRaisedParam = cmd.Parameters.Add("@AlertRaised", System.Data.SqlDbType.Bit);
        alertRaisedParam.Direction = System.Data.ParameterDirection.Output;

        await cmd.ExecuteNonQueryAsync();

        var readingId   = (long)readingIdParam.Value;
        var alertRaised = (bool)alertRaisedParam.Value;

        _logger.LogInformation(
            "Ingested reading {ReadingID} for sensor {SensorCode} — value: {Value}{AlertSuffix}",
            readingId, message.SensorCode, message.Value,
            alertRaised ? " ⚠️ ALERT RAISED" : "");

        // Trigger snapshot refresh asynchronously
        if (alertRaised)
        {
            _logger.LogWarning(
                "Anomaly detected on sensor {SensorCode} with value {Value}",
                message.SensorCode, message.Value);
        }
    }
}

public record SensorReadingMessage(
    string SensorCode,
    decimal Value,
    DateTimeOffset Timestamp,
    string? RawPayload = null
);
