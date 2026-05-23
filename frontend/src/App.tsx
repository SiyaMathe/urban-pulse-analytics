import { useState, useEffect } from 'react';
import './App.css';

interface PerformanceMetric {
  sensorCode: string;
  metricType: string;
  city: string;
  country: string;
  hour: string;
  avgValue: number;
  peakValue: number;
  totalPackets: number;
  anomalies: number;
  unit: string;
}

function App() {
  const [metrics, setMetrics] = useState<PerformanceMetric[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const fetchPlatformData = async () => {
      try {
        // Fetching directly from your live local .NET Core endpoint
        const response = await fetch('http://localhost:5000/api/analytics/performance');
        if (!response.ok) {
          throw new Error(`HTTP fault code: ${response.status}`);
        }
        const data = await response.json();
        setMetrics(data);
        setError(null);
      } catch (err: any) {
        setError(err.message || "Failed to establish a communication route with API.");
      } finally {
        setLoading(false);
      }
    };

    // Initial fetch and poll telemetry metrics every 5 seconds
    fetchPlatformData();
    const networkInterval = setInterval(fetchPlatformData, 5000);

    return () => clearInterval(networkInterval);
  }, []);

  return (
    <div className="dashboard-container" style={{ padding: '24px', fontFamily: 'sans-serif', color: '#fff', backgroundColor: '#121214', minHeight: '100vh' }}>
      
      {/* Header Panel */}
      <header style={{ marginBottom: '32px', borderBottom: '1px solid #29292e', paddingBottom: '16px' }}>
        <h1 style={{ fontSize: '28px', margin: '0 0 8px 0', color: '#00b37e' }}>Urban Pulse Analytics Platform</h1>
        <p style={{ margin: '0', color: '#a8a8b3' }}>
          Real-Time Multi-City Telemetry Operations Console Center — <span style={{ color: '#00b37e', fontWeight: 'bold' }}>● Operational Live Connection</span>
        </p>
      </header>

      {/* Error/Loading Boundary Displays */}
      {loading && <div style={{ color: '#e1e1e6', fontSize: '18px' }}>Ingesting platform telemetry records...</div>}
      {error && (
        <div style={{ backgroundColor: '#f75a68', color: '#fff', padding: '16px', borderRadius: '6px', marginBottom: '24px' }}>
          <strong>System Connection Fault:</strong> {error}
        </div>
      )}

      {/* Main Metrics Matrix Grid */}
      {!loading && !error && (
        <div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: '20px', marginBottom: '32px' }}>
            <div style={{ backgroundColor: '#202024', padding: '20px', borderRadius: '8px', border: '1px solid #29292e' }}>
              <h3 style={{ margin: '0 0 10px 0', color: '#c4c4cc', fontSize: '14px', textTransform: 'uppercase' }}>Ingested Packets Counter</h3>
              <p style={{ fontSize: '32px', margin: '0', fontWeight: 'bold', color: '#e1e1e6' }}>
                {metrics.reduce((acc, curr) => acc + curr.totalPackets, 0).toLocaleString()}
              </p>
            </div>
            <div style={{ backgroundColor: '#202024', padding: '20px', borderRadius: '8px', border: '1px solid #29292e' }}>
              <h3 style={{ margin: '0 0 10px 0', color: '#c4c4cc', fontSize: '14px', textTransform: 'uppercase' }}>System Flagged Anomalies</h3>
              <p style={{ fontSize: '32px', margin: '0', fontWeight: 'bold', color: '#f75a68' }}>
                {metrics.reduce((acc, curr) => acc + curr.anomalies, 0)}
              </p>
            </div>
          </div>

          <h2 style={{ fontSize: '20px', marginBottom: '16px', color: '#e1e1e6' }}>Active Node Sensor Performance Real-Time Log</h2>
          <div style={{ overflowX: 'auto', backgroundColor: '#202024', borderRadius: '8px', border: '1px solid #29292e' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', textAlign: 'left' }}>
              <thead>
                <tr style={{ borderBottom: '2px solid #29292e', color: '#c4c4cc' }}>
                  <th style={{ padding: '16px' }}>Sensor Type</th>
                  <th style={{ padding: '16px' }}>Target Region</th>
                  <th style={{ padding: '16px' }}>Hourly Average</th>
                  <th style={{ padding: '16px' }}>Peak Value</th>
                  <th style={{ padding: '16px' }}>Volume Packets</th>
                  <th style={{ padding: '16px' }}>Anomalies</th>
                </tr>
              </thead>
              <tbody>
                {metrics.map((metric, index) => (
                  <tr key={index} style={{ borderBottom: '1px solid #29292e', color: '#e1e1e6' }} className="table-row-hover">
                    <td style={{ padding: '16px' }}><code style={{ color: '#00b37e', backgroundColor: '#121214', padding: '4px 8px', borderRadius: '4px' }}>{metric.metricType}</code></td>
                    <td style={{ padding: '16px' }}>{metric.city}, {metric.country}</td>
                    <td style={{ padding: '16px' }}>{metric.avgValue.toFixed(2)} <span style={{ fontSize: '12px', color: '#7c7c8a' }}>{metric.unit}</span></td>
                    <td style={{ padding: '16px' }}>{metric.peakValue.toFixed(2)} {metric.unit}</td>
                    <td style={{ padding: '16px' }}>{metric.totalPackets} msgs</td>
                    <td style={{ padding: '16px', color: metric.anomalies > 0 ? '#f75a68' : '#e1e1e6', fontWeight: metric.anomalies > 0 ? 'bold' : 'normal' }}>
                      {metric.anomalies}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}

export default App;