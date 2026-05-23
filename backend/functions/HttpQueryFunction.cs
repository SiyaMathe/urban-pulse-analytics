using System;
using System.Net;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace UrbanPulse.Functions;

/// <summary>
/// HTTP-triggered Azure Function exposing sensor analytics endpoints.
///
/// Endpoints:
///   GET /api/health
///   GET /api/sensors/status
///   GET /api/cities/{cityId}/snapshot
///   POST /api/readings/bulk
/// </summary>
public class HttpQueryFunction
{
    private readonly ILogger<HttpQueryFunction> _logger;
    private readonly string _connectionString;

    public HttpQueryFunction(ILogger<HttpQueryFunction> logger)
    {
        _logger = logger;
        _connectionString = Environment.GetEnvironmentVariable("AZURE_SQL_CONNECTION_STRING")!;
    }

    // ── Health check ────────────────────────────────────────────────────────
    [Function("Health")]
    public async Task<HttpResponseData> Health(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "health")] HttpRequestData req)
    {
        var response = req.CreateResponse(HttpStatusCode.OK);

        bool dbHealthy = await CheckDatabaseAsync();

        await response.WriteAsJsonAsync(new
        {
            status    = dbHealthy ? "healthy" : "degraded",
            timestamp = DateTimeOffset.UtcNow,
            version   = "1.0.0",
            components = new
            {
                database = dbHealthy ? "ok" : "error",
                functions = "ok"
            }
        });

        return response;
    }

    // ── Sensor status dashboard ─────────────────────────────────────────────
    [Function("GetSensorStatus")]
    public async Task<HttpResponseData> GetSensorStatus(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "sensors/status")] HttpRequestData req)
    {
        var response = req.CreateResponse(HttpStatusCode.OK);
        var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);

        var cityId      = query["cityId"];
        var statusFilter = query["status"];

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync();

        var sql = @"
            SELECT
                SensorID, SensorCode, CityName, SensorType, Unit,
                LatestValue, LastReadingAt, LatestIsAnomaly,
                ActiveAlerts, SensorStatus, IsActive
            FROM dbo.vw_SensorStatus
            WHERE 1 = 1
              AND (@CityId   IS NULL OR CityID = @CityId)
              AND (@Status   IS NULL OR SensorStatus = @Status)
            ORDER BY CityName, SensorCode";

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@CityId", cityId is not null ? int.Parse(cityId) : DBNull.Value);
        cmd.Parameters.AddWithValue("@Status", statusFilter is not null ? statusFilter : DBNull.Value);

        var results = new System.Collections.Generic.List<object>();
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            results.Add(new
            {
                sensorId     = reader.GetInt32(0),
                sensorCode   = reader.GetString(1),
                cityName     = reader.GetString(2),
                sensorType   = reader.GetString(3),
                unit         = reader.GetString(4),
                latestValue  = reader.IsDBNull(5)  ? (decimal?)null : reader.GetDecimal(5),
                lastReadingAt = reader.IsDBNull(6) ? (DateTime?)null : reader.GetDateTime(6),
                isAnomaly    = reader.IsDBNull(7)  ? false : reader.GetBoolean(7),
                activeAlerts = reader.GetInt32(8),
                status       = reader.GetString(9),
                isActive     = reader.GetBoolean(10)
            });
        }

        await response.WriteAsJsonAsync(new { data = results, count = results.Count });
        return response;
    }

    // ── City analytics snapshot ─────────────────────────────────────────────
    [Function("GetCitySnapshot")]
    public async Task<HttpResponseData> GetCitySnapshot(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "cities/{cityId}/snapshot")] HttpRequestData req,
        int cityId)
    {
        var response = req.CreateResponse(HttpStatusCode.OK);
        var query = System.Web.HttpUtility.ParseQueryString(req.Url.Query);
        var hours = int.TryParse(query["hours"], out var h) ? h : 24;

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync();

        // Pull from pre-computed snapshots (Gold layer)
        const string sql = @"
            SELECT
                ans.SnapshotHour,
                st.TypeCode         AS SensorType,
                st.Unit,
                ans.AvgValue,
                ans.MinValue,
                ans.MaxValue,
                ans.ReadingCount,
                ans.AlertCount,
                -- Trend indicator vs previous hour
                ans.AvgValue - LAG(ans.AvgValue) OVER (
                    PARTITION BY ans.SensorTypeID
                    ORDER BY ans.SnapshotHour
                ) AS HoH_Change
            FROM       dbo.AnalyticsSnapshot ans
            JOIN       dbo.SensorType         st  ON st.SensorTypeID = ans.SensorTypeID
            WHERE      ans.CityID       = @CityId
              AND      ans.SnapshotHour >= DATEADD(HOUR, -@Hours, SYSUTCDATETIME())
            ORDER BY   ans.SnapshotHour DESC, st.TypeCode";

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@CityId", cityId);
        cmd.Parameters.AddWithValue("@Hours",  hours);

        var snapshots = new System.Collections.Generic.List<object>();
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            snapshots.Add(new
            {
                snapshotHour  = reader.GetDateTime(0),
                sensorType    = reader.GetString(1),
                unit          = reader.GetString(2),
                avgValue      = reader.GetDecimal(3),
                minValue      = reader.GetDecimal(4),
                maxValue      = reader.GetDecimal(5),
                readingCount  = reader.GetInt32(6),
                alertCount    = reader.GetInt32(7),
                hohChange     = reader.IsDBNull(8) ? (decimal?)null : reader.GetDecimal(8)
            });
        }

        await response.WriteAsJsonAsync(new
        {
            cityId,
            periodHours = hours,
            snapshots,
            snapshotCount = snapshots.Count
        });

        return response;
    }

    // ── Bulk reading ingest via HTTP (e.g. from IoT gateway) ───────────────
    [Function("BulkIngestReadings")]
    public async Task<HttpResponseData> BulkIngestReadings(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "readings/bulk")] HttpRequestData req)
    {
        var body = await req.ReadAsStringAsync();

        if (string.IsNullOrWhiteSpace(body))
        {
            var badReq = req.CreateResponse(HttpStatusCode.BadRequest);
            await badReq.WriteStringAsync("Request body is required.");
            return badReq;
        }

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync();

        await using var cmd = new SqlCommand("dbo.usp_BulkIngestFromJson", connection)
        {
            CommandType = System.Data.CommandType.StoredProcedure,
            CommandTimeout = 60
        };

        cmd.Parameters.AddWithValue("@JsonPayload", body);
        var successParam = cmd.Parameters.Add("@SuccessCount", System.Data.SqlDbType.Int);
        var failureParam = cmd.Parameters.Add("@FailureCount", System.Data.SqlDbType.Int);
        successParam.Direction = System.Data.ParameterDirection.Output;
        failureParam.Direction = System.Data.ParameterDirection.Output;

        await cmd.ExecuteNonQueryAsync();

        int success = (int)successParam.Value;
        int failure = (int)failureParam.Value;

        _logger.LogInformation("Bulk ingest: {Success} succeeded, {Failure} failed", success, failure);

        var response = req.CreateResponse(
            failure == 0 ? HttpStatusCode.OK : HttpStatusCode.MultiStatus);

        await response.WriteAsJsonAsync(new
        {
            successCount  = success,
            failureCount  = failure,
            processedAt   = DateTimeOffset.UtcNow
        });

        return response;
    }

    private async Task<bool> CheckDatabaseAsync()
    {
        try
        {
            await using var connection = new SqlConnection(_connectionString);
            await connection.OpenAsync();
            await using var cmd = new SqlCommand("SELECT 1", connection);
            await cmd.ExecuteScalarAsync();
            return true;
        }
        catch { return false; }
    }
}