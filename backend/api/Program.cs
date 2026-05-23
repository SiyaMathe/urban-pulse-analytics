using Microsoft.OpenApi.Models;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new OpenApiInfo { Title = "Urban Pulse Analytics REST API", Version = "v1" });
});

// Register your Database connection configuration mapping
string? connectionString = builder.Configuration.GetConnectionString("AzureSql") 
    ?? Environment.GetEnvironmentVariable("AZURE_SQL_CONNECTION_STRING");

var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment() || app.IsEnabled("SwaggerUI"))
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();

app.Run();

// Helper extension method to check configuration flags
public static class EnvExtensions
{
    public static bool IsEnabled(this IWebHostEnvironment env, string key)
    {
        return string.Equals(Environment.GetEnvironmentVariable(key), "true", StringComparison.OrdinalIgnoreCase);
    }
}