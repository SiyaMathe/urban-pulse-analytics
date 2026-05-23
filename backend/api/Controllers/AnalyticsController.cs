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
        private readonly ILogger<AnalyticsController> _logger;

        public AnalyticsController(IConfiguration configuration, ILogger<AnalyticsController> logger)
        {
            _logger = logger;
            _connectionString = configuration.GetConnectionString("AzureSql") ?? "";

            if (string.IsNullOrEmpty(_connectionString))
            {
                _logger.LogError("CRITICAL: 'AzureSql' connection string key was NOT found!");
            }
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
                string query = @"
                    SELECT TOP 100 
                        st.TypeCode   AS SensorCode, 
                        st.TypeCode   AS SensorMetricType, 
                        c.CityName    AS CityName, 
                        co.CountryName AS Country, 
                        v.HourBucket  AS ReadingHour, 
                        v.HourlyAvg   AS AvgHourlyValue, 
                        v.HourlyMax   AS MaxHourlyPeak, 
                        v.ReadingCount AS TotalIngestedPackets, 
                        v.AnomalyCount AS TotalTriggeredAnomalies, 
                        st.Unit       AS MeasurementUnit
                    FROM dbo.vw_HourlyTrendWithRollingAvg v
                    JOIN dbo.City c ON c.CityName = v.CityName
                    JOIN dbo.Country co ON co.CountryID = c.CountryID
                    JOIN dbo.SensorType st ON st.TypeCode = v.SensorType
                    ORDER BY v.HourBucket DESC;";
                
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