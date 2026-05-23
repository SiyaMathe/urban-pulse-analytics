# Urban Pulse Analytics
### Cloud-Native Real-Time Data Pipeline & Analytics Platform

> **Skills Demonstrated:** Azure Cloud Architecture · Advanced SQL (Stored Procedures, Views, CTEs, Window Functions) · Database Normalization (3NF) · Azure Functions · REST API Design · Queue-Triggered Pipelines · NoSQL (MongoDB) · CI/CD with GitHub Actions · IaC (Bicep) · Python · C#

---

## 🏗️ Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                     URBAN PULSE ANALYTICS                        │
│                                                                  │
│  Data Sources → Azure Event Hub → Azure Functions (Queue)        │
│                                    ↓                             │
│               Bronze Layer (Raw ADLS Gen2 Blob)                  │
│                                    ↓                             │
│               Silver Layer (Azure SQL — Cleaned/Normalized)      │
│                                    ↓                             │
│               Gold Layer  (Aggregated Views + Analytics API)     │
│                                    ↓                             │
│               REST API (Azure App Service) → Dashboard           │
└──────────────────────────────────────────────────────────────────┘
```

**Stack:**
- **Compute:** Azure Functions v4 (C#), Azure App Service (.NET 8)
- **Storage:** Azure SQL Database, Azure Blob Storage (ADLS Gen2), Azure Storage Queue
- **Messaging:** Azure Storage Queues (Queue-triggered Functions)
- **Monitoring:** Application Insights, Azure Monitor
- **IaC:** Azure Bicep
- **CI/CD:** GitHub Actions → Azure

---

## 📁 Project Structure

```
urban-pulse-analytics/
├── backend/
│   ├── api/                    # .NET 8 REST API (Azure App Service)
│   │   ├── Controllers/
│   │   ├── Models/
│   │   ├── Services/
│   │   └── UrbanPulse.Api.csproj
│   ├── functions/              # Azure Functions (Queue + HTTP triggers)
│   │   ├── QueueIngestFunction.cs
│   │   ├── HttpQueryFunction.cs
│   │   └── UrbanPulse.Functions.csproj
│   ├── sql/                    # All SQL — schema, stored procs, views
│   │   ├── 01_schema.sql
│   │   ├── 02_stored_procedures.sql
│   │   ├── 03_views.sql
│   │   ├── 04_seed_data.sql
│   │   └── 05_analytics_queries.sql
│   └── migrations/             # Flyway-style versioned migrations
│       ├── V1__initial_schema.sql
│       └── V2__add_analytics_views.sql
├── frontend/                   # React dashboard (Azure Static Web Apps)
│   ├── src/
│   └── package.json
├── infrastructure/             # Azure Bicep IaC
│   ├── main.bicep
│   └── modules/
├── tests/
│   ├── api.tests/
│   └── sql.tests/
├── .github/
│   └── workflows/
│       ├── ci.yml              # Run tests on every PR
│       └── cd.yml              # Deploy to Azure on merge to main
├── .vscode/
│   ├── extensions.json
│   └── launch.json
├── docker-compose.yml          # Local dev (SQL Server + API)
└── README.md
```

---

## 🚀 Quick Start (Local Development)

### Prerequisites
- [VS Code](https://code.visualstudio.com/) with extensions (see `.vscode/extensions.json`)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- [Azure Functions Core Tools v4](https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local)
- [Node.js 20+](https://nodejs.org/) (for dashboard)

### 1. Clone & Configure

```bash
git clone https://github.com/SiyaMathe/urban-pulse-analytics.git
cd urban-pulse-analytics
cp .env.example .env
# Edit .env with your Azure connection strings
```

### 2. Spin Up Local Stack

```bash
docker-compose up -d          # Starts SQL Server + Azurite (local Azure storage emulator)
```

### 3. Apply Database Migrations

```bash
cd backend/sql
# Using sqlcmd (comes with SQL Server tools)
sqlcmd -S localhost,1433 -U sa -P YourPassword123! -i 01_schema.sql
sqlcmd -S localhost,1433 -U sa -P YourPassword123! -i 02_stored_procedures.sql
sqlcmd -S localhost,1433 -U sa -P YourPassword123! -i 03_views.sql
sqlcmd -S localhost,1433 -U sa -P YourPassword123! -i 04_seed_data.sql
```

### 4. Run the API

```bash
cd backend/api
dotnet restore
dotnet run
# API available at https://localhost:7001
```

### 5. Run Azure Functions Locally

```bash
cd backend/functions
func start
# Functions available at http://localhost:7071
```

### 6. Run the Dashboard

```bash
cd frontend
npm install
npm run dev
# Dashboard at http://localhost:5173
```

---

## ☁️ Deploy to Azure

### One-time Setup

```bash
# Login
az login

# Create resource group
az group create --name urban-pulse-rg --location southafricanorth

# Deploy infrastructure (Bicep)
az deployment group create \
  --resource-group urban-pulse-rg \
  --template-file infrastructure/main.bicep \
  --parameters @infrastructure/parameters.prod.json
```

### CI/CD via GitHub Actions

Add the following secrets to your GitHub repo (`Settings → Secrets → Actions`):

| Secret | Description |
|--------|-------------|
| `AZURE_CREDENTIALS` | Output of `az ad sp create-for-rbac` |
| `AZURE_SQL_CONNECTION_STRING` | Azure SQL connection string |
| `AZURE_STORAGE_CONNECTION_STRING` | Azure Storage connection string |
| `AZURE_FUNCTIONAPP_NAME` | Your Function App name |
| `AZURE_WEBAPP_NAME` | Your Web App name |

Then every push to `main` triggers the full CI/CD pipeline automatically.

---

## 🗄️ Database Design

The schema is fully normalized to **3NF** with surrogate PKs throughout.

### Entity Relationship Overview

```
City (1) ──────< Sensor (*) >────── SensorReading (*)
                    |
                    └──── SensorType (1)

Alert (*) >────── Sensor (1)
Alert (*) >────── AlertType (1)

AnalyticsSnapshot (*) >────── City (1)
```

See `backend/sql/01_schema.sql` for the full normalized schema with all constraints.

---

## 📊 Key SQL Features Showcased

| Feature | Location |
|---------|----------|
| 3NF Normalized Schema | `01_schema.sql` |
| Stored Procedures (CRUD + business logic) | `02_stored_procedures.sql` |
| Complex Views with CTEs | `03_views.sql` |
| Window Functions (LAG, LEAD, RANK) | `05_analytics_queries.sql` |
| Aggregations + GROUP BY ROLLUP | `05_analytics_queries.sql` |
| Dynamic SQL | `02_stored_procedures.sql` |
| Transactions + Error Handling | `02_stored_procedures.sql` |
| MongoDB NoSQL queries | `backend/nosql/` |

---

## 🧪 Testing

```bash
# Run all tests
dotnet test

# Run SQL tests (uses tSQLt framework concepts)
cd tests/sql.tests
sqlcmd -S localhost,1433 -U sa -P YourPassword123! -i run_tests.sql
```

---

## 📋 VS Code Extensions Required

Install all recommended extensions at once:
1. Open VS Code in the project root
2. Press `Ctrl+Shift+P` → "Extensions: Show Recommended Extensions"
3. Click "Install All"

Or install manually (see `.vscode/extensions.json`).

---

## 🔗 Live Demo

- **API Swagger Docs:** `https://<your-webapp>.azurewebsites.net/swagger`
- **Dashboard:** `https://<your-staticwebapp>.azurestaticapps.net`
- **Function Health:** `https://<your-functionapp>.azurewebsites.net/api/health`
