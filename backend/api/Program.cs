using Microsoft.OpenApi.Models;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new OpenApiInfo { Title = "Urban Pulse Analytics REST API", Version = "v1" });
});

// Configure Database Connection String
string? connectionString = builder.Configuration.GetConnectionString("AzureSql") 
    ?? Environment.GetEnvironmentVariable("AZURE_SQL_CONNECTION_STRING");

var app = builder.Build();

// Configure the HTTP request pipeline.
// This enables Swagger in Development mode or if explicitly requested via environment variables
if (app.Environment.IsDevelopment() || Environment.GetEnvironmentVariable("SwaggerUI") == "true")
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();

app.Run();