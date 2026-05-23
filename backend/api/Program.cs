using Microsoft.OpenApi.Models;

var builder = WebApplication.CreateBuilder(args);

// 1. Add CORS services
builder.Services.AddCors(options => {
    options.AddPolicy("AllowLocalhost", policy => {
        policy.WithOrigins("http://localhost:5173") // Your Vite frontend
              .AllowAnyHeader()
              .AllowAnyMethod();
    });
});

builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new OpenApiInfo { Title = "Urban Pulse Analytics REST API", Version = "v1" });
});

var app = builder.Build();

if (app.Environment.IsDevelopment() || Environment.GetEnvironmentVariable("SwaggerUI") == "true")
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();

// 2. Enable CORS middleware (MUST be placed before MapControllers)
app.UseCors("AllowLocalhost");

app.UseAuthorization();
app.MapControllers();

app.Run();