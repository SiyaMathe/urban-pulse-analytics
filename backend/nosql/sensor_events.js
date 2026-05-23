// =============================================================================
// Urban Pulse Analytics — NoSQL (MongoDB) Sensor Event Store
// Demonstrates: Collection design, compound indexes, aggregation pipeline,
//               $lookup (join), $facet (multi-facet aggregation), $bucket,
//               $geoNear, text search, time-series collection
// =============================================================================

// ── 1. Create / switch to database ────────────────────────────────────────────
use urbanpulse_events;

// ── 2. Time-series collection for raw sensor events (MongoDB 5.0+) ────────────
// Time-series collections are optimised for sequential inserts & range reads
db.createCollection("sensor_events", {
  timeseries: {
    timeField:   "timestamp",
    metaField:   "metadata",
    granularity: "minutes"
  },
  expireAfterSeconds: 2592000  // Auto-expire after 30 days (cold data moves to SQL)
});

// ── 3. Regular collection for sensor config / metadata ────────────────────────
db.createCollection("sensor_registry");

// Compound index: city + type + active status (mirrors SQL index strategy)
db.sensor_registry.createIndex(
  { "city.code": 1, "sensor_type": 1, "is_active": 1 },
  { name: "ix_city_type_active" }
);

// Text index for full-text search on sensor description
db.sensor_registry.createIndex(
  { "description": "text", "city.name": "text" },
  { name: "ix_text_search" }
);

// Geospatial index for location-based queries
db.sensor_registry.createIndex(
  { "location.coordinates": "2dsphere" },
  { name: "ix_geospatial" }
);

// ── 4. Insert sensor registry documents ────────────────────────────────────────
db.sensor_registry.insertMany([
  {
    sensor_code:  "JHB-AQ-001",
    sensor_type:  "AIR_QUALITY",
    description:  "Air quality monitor — Sandton CBD",
    city: {
      code: "JHB",
      name: "Johannesburg",
      country: "ZA"
    },
    location: {
      type: "Point",
      coordinates: [28.0567, -26.1076]  // [lng, lat] for GeoJSON
    },
    unit:         "AQI",
    thresholds: {
      warning:  100,
      critical: 150
    },
    is_active:    true,
    installed_at: ISODate("2023-01-15T00:00:00Z"),
    tags:         ["outdoor", "cbd", "priority-1"]
  },
  {
    sensor_code:  "CPT-AQ-001",
    sensor_type:  "AIR_QUALITY",
    description:  "Air quality monitor — Cape Town City Bowl",
    city: {
      code: "CPT",
      name: "Cape Town",
      country: "ZA"
    },
    location: {
      type: "Point",
      coordinates: [18.4232, -33.9258]
    },
    unit:         "AQI",
    thresholds: {
      warning:  100,
      critical: 150
    },
    is_active:    true,
    installed_at: ISODate("2023-03-01T00:00:00Z"),
    tags:         ["outdoor", "city-bowl"]
  },
  {
    sensor_code:  "JHB-TR-001",
    sensor_type:  "TRAFFIC",
    description:  "Traffic counter — N1 Highway Midrand",
    city: {
      code: "JHB",
      name: "Johannesburg",
      country: "ZA"
    },
    location: {
      type: "Point",
      coordinates: [28.1326, -25.9976]
    },
    unit:         "vehicles/hr",
    thresholds: {
      warning:  1500,
      critical: 2000
    },
    is_active:    true,
    installed_at: ISODate("2023-02-01T00:00:00Z"),
    tags:         ["highway", "n1"]
  }
]);

// ── 5. Insert sensor events (time-series) ─────────────────────────────────────
db.sensor_events.insertMany([
  {
    timestamp: ISODate("2024-01-15T07:00:00Z"),
    metadata:  { sensor_code: "JHB-AQ-001", city: "JHB", type: "AIR_QUALITY" },
    value:     87.4,
    is_anomaly: false,
    raw: { pm25: 24.1, pm10: 48.3, o3: 18.7 }
  },
  {
    timestamp: ISODate("2024-01-15T08:00:00Z"),
    metadata:  { sensor_code: "JHB-AQ-001", city: "JHB", type: "AIR_QUALITY" },
    value:     142.6,
    is_anomaly: true,
    raw: { pm25: 58.2, pm10: 112.4, o3: 22.1 }
  },
  {
    timestamp: ISODate("2024-01-15T07:00:00Z"),
    metadata:  { sensor_code: "JHB-TR-001", city: "JHB", type: "TRAFFIC" },
    value:     1820,
    is_anomaly: false,
    raw: { northbound: 980, southbound: 840 }
  },
  {
    timestamp: ISODate("2024-01-15T07:00:00Z"),
    metadata:  { sensor_code: "CPT-AQ-001", city: "CPT", type: "AIR_QUALITY" },
    value:     45.2,
    is_anomaly: false,
    raw: { pm25: 8.1, pm10: 18.4, o3: 14.2 }
  }
]);

// ── 6. Aggregation pipeline — hourly averages per city ────────────────────────
// Equivalent to the SQL rolling average view but in MongoDB
db.sensor_events.aggregate([
  // Stage 1: Filter last 24 hours
  {
    $match: {
      timestamp: { $gte: new Date(Date.now() - 24 * 60 * 60 * 1000) }
    }
  },
  // Stage 2: Group by city + sensor type + hour bucket
  {
    $group: {
      _id: {
        city:       "$metadata.city",
        type:       "$metadata.type",
        hour:       { $dateTrunc: { date: "$timestamp", unit: "hour" } }
      },
      avg_value:     { $avg: "$value" },
      min_value:     { $min: "$value" },
      max_value:     { $max: "$value" },
      reading_count: { $sum: 1 },
      anomaly_count: { $sum: { $cond: ["$is_anomaly", 1, 0] } }
    }
  },
  // Stage 3: Calculate anomaly rate
  {
    $addFields: {
      anomaly_rate_pct: {
        $multiply: [
          { $divide: ["$anomaly_count", "$reading_count"] },
          100
        ]
      }
    }
  },
  // Stage 4: Sort by city, type, hour
  { $sort: { "_id.city": 1, "_id.type": 1, "_id.hour": -1 } },
  // Stage 5: Project clean output
  {
    $project: {
      _id: 0,
      city:          "$_id.city",
      sensor_type:   "$_id.type",
      hour:          "$_id.hour",
      avg_value:     { $round: ["$avg_value", 2] },
      min_value:     { $round: ["$min_value", 2] },
      max_value:     { $round: ["$max_value", 2] },
      reading_count: 1,
      anomaly_count: 1,
      anomaly_rate_pct: { $round: ["$anomaly_rate_pct", 2] }
    }
  }
]);

// ── 7. $facet — multi-dimensional analysis in one query ───────────────────────
// Returns city breakdown + type breakdown + anomaly buckets simultaneously
db.sensor_events.aggregate([
  { $match: { timestamp: { $gte: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000) } } },
  {
    $facet: {
      // Facet 1: Readings per city
      by_city: [
        { $group: { _id: "$metadata.city", count: { $sum: 1 }, avg: { $avg: "$value" } } },
        { $sort: { count: -1 } }
      ],
      // Facet 2: Readings per sensor type
      by_type: [
        { $group: { _id: "$metadata.type", count: { $sum: 1 }, anomalies: { $sum: { $cond: ["$is_anomaly", 1, 0] } } } },
        { $sort: { anomalies: -1 } }
      ],
      // Facet 3: Value distribution buckets (histogram)
      value_histogram: [
        {
          $bucket: {
            groupBy: "$value",
            boundaries: [0, 50, 100, 150, 200, 300, 500],
            default: "500+",
            output: { count: { $sum: 1 } }
          }
        }
      ],
      // Facet 4: Summary stats
      summary: [
        {
          $group: {
            _id: null,
            total_readings: { $sum: 1 },
            total_anomalies: { $sum: { $cond: ["$is_anomaly", 1, 0] } },
            overall_avg: { $avg: "$value" }
          }
        }
      ]
    }
  }
]);

// ── 8. $lookup — join events with sensor registry ─────────────────────────────
// Find all anomalous events enriched with sensor metadata
db.sensor_events.aggregate([
  { $match: { is_anomaly: true } },
  {
    $lookup: {
      from:         "sensor_registry",
      localField:   "metadata.sensor_code",
      foreignField: "sensor_code",
      as:           "sensor_info"
    }
  },
  { $unwind: "$sensor_info" },
  {
    $project: {
      timestamp:         1,
      value:             1,
      "sensor_info.description":       1,
      "sensor_info.city":              1,
      "sensor_info.thresholds":        1,
      exceeded_critical: {
        $gt: ["$value", "$sensor_info.thresholds.critical"]
      }
    }
  },
  { $sort: { timestamp: -1 } }
]);

// ── 9. $geoNear — find sensors within 10km of a point ─────────────────────────
db.sensor_registry.aggregate([
  {
    $geoNear: {
      near: {
        type: "Point",
        coordinates: [28.0473, -26.2041]  // Johannesburg CBD
      },
      distanceField:  "distance_meters",
      maxDistance:    10000,              // 10km radius
      spherical:      true,
      query:          { is_active: true }
    }
  },
  {
    $project: {
      sensor_code:     1,
      sensor_type:     1,
      description:     1,
      "city.name":     1,
      distance_km:     { $divide: ["$distance_meters", 1000] }
    }
  },
  { $sort: { distance_meters: 1 } }
]);

// ── 10. Text search ────────────────────────────────────────────────────────────
db.sensor_registry.find(
  { $text: { $search: "highway traffic N1" } },
  { score: { $meta: "textScore" }, sensor_code: 1, description: 1 }
).sort({ score: { $meta: "textScore" } });

// ── 11. Get all sensors — basic query ─────────────────────────────────────────
db.sensor_registry.find({ is_active: true }).sort({ "city.name": 1, sensor_code: 1 });

// ── 12. Query events where value <= 100 ───────────────────────────────────────
db.sensor_events.find(
  {
    "metadata.type": "AIR_QUALITY",
    value: { $lte: 100 },
    timestamp: { $gte: ISODate("2024-01-15T00:00:00Z") }
  },
  { timestamp: 1, "metadata.sensor_code": 1, value: 1, is_anomaly: 1 }
).sort({ timestamp: -1 });

print("All MongoDB queries executed successfully.");
