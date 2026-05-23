using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using System.Data;

namespace UrbanPulse.Api.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class AnalyticsController : ControllerBase
    {
        private readonly string _connectionString;

        public AnalyticsController(IConfiguration configuration)
        {
            _connectionString = configuration.GetConnectionString("AzureSql") 
                ?? Environment.GetEnvironmentVariable("AZURE_SQL_CONNECTION_STRING") 
                ?? "";
        }

        [HttpGet("performance")]
        public async Task<IActionResult> GetSensorPerformance()
        {
            if (string.IsNullOrEmpty(_connectionString))
            {
                return StatusCode(500, "Database connection string is unconfigured.");
            }

            var performanceRecords = new List<object>();

            using (var connection = new SqlConnection(_connectionString))
            {
                // Reading directly from your view
                string query = "SELECT TOP 100 * FROM dbo.vw_DetailedSensorPerformance ORDER BY ReadingHour DESC;";
                
                using (var command = new SqlCommand(query, connection))
                {
                    try
                    {
                        await connection.OpenAsync();
                        using (var reader = await command.ExecuteReaderAsync())
                        {
                            while (await reader.ReadAsync())
                            {
                                performanceRecords.Add(new
                                {
                                    SensorCode = reader["SensorCode"].ToString(),
                                    MetricType = reader["SensorMetricType"].ToString(),
                                    City = reader["CityName"].ToString(),
                                    Country = reader["Country"].ToString(),
                                    Hour = reader["ReadingHour"],
                                    AvgValue = reader["AvgHourlyValue"],
                                    PeakValue = reader["MaxHourlyPeak"],
                                    TotalPackets = reader["TotalIngestedPackets"],
                                    Anomalies = reader["TotalTriggeredAnomalies"],
                                    Unit = reader["MeasurementUnit"].ToString()
                                });
                            }
                        }
                    }
                    catch (SqlException ex)
                    {
                        return StatusCode(500, $"Database evaluation fault: {ex.Message}");
                    }
                }
            }

            return Ok(performanceRecords);
        }
    }
}