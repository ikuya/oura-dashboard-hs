import { mainPeriod } from "./helpers.js";

// One row per day of the selected range, built from what the dashboard already
// loaded, so the file holds exactly the numbers the charts are drawing.
// Stage durations add up every period of the day (the night plus naps); the
// clock times and vitals come from the main period alone, the same split the
// Bedtime / Wake and Nightly HRV charts make.

const minutes = (seconds) => seconds == null ? null : Math.round(seconds / 60);
const sumOf = (rows, field) =>
  rows.some((r) => r[field] != null)
    ? rows.reduce((total, r) => total + (r[field] ?? 0), 0)
    : null;

const DAILY_COLUMNS = [
  ["readiness_score", "readiness", (r) => r.score],
  ["sleep_score", "sleep", (r) => r.score],
  ["activity_score", "activity", (r) => r.score],
  ["steps", "activity", (r) => r.steps],
  ["active_calories", "activity", (r) => r.active_calories],
  ["stress_high_min", "stress", (r) => minutes(r.stress_high)],
  ["recovery_high_min", "stress", (r) => minutes(r.recovery_high)],
  ["spo2_pct", "spo2", (r) => r.score],
  ["temperature_deviation_c", "temperature", (r) => r.temperature_deviation ?? r.score],
  ["resilience_level", "resilience", (r) => r.level],
  ["vascular_age", "cardiovascular_age", (r) => r.vascular_age ?? r.score],
];

const SLEEP_COLUMNS = [
  ["bedtime_start", (_, main) => main?.bedtime_start],
  ["bedtime_end", (_, main) => main?.bedtime_end],
  ["total_sleep_min", (all) => minutes(sumOf(all, "total_sleep_duration"))],
  ["deep_sleep_min", (all) => minutes(sumOf(all, "deep_sleep_duration"))],
  ["rem_sleep_min", (all) => minutes(sumOf(all, "rem_sleep_duration"))],
  ["light_sleep_min", (all) => minutes(sumOf(all, "light_sleep_duration"))],
  ["awake_min", (all) => minutes(sumOf(all, "awake_time"))],
  ["sleep_efficiency", (_, main) => main?.efficiency],
  ["average_hrv_ms", (_, main) => main?.average_hrv],
  ["lowest_heart_rate", (_, main) => main?.lowest_heart_rate],
  ["average_heart_rate", (_, main) => main?.average_heart_rate],
  ["average_breath", (_, main) => main?.average_breath],
];

function csvField(v) {
  if (v == null) return "";
  const s = String(v);
  return /[",\r\n]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s;
}

export function dailyCsvRows(data, periods) {
  const byMetric = Object.fromEntries(
    Object.entries(data).map(([m, rows]) => [m, new Map(rows.map((r) => [r.day, r]))]));
  const periodsByDay = new Map();
  for (const p of periods) periodsByDay.set(p.day, [...(periodsByDay.get(p.day) ?? []), p]);
  const days = [...new Set([
    ...Object.values(data).flatMap((rows) => rows.map((r) => r.day)),
    ...periodsByDay.keys(),
  ])].sort();

  const header = ["day", ...DAILY_COLUMNS.map(([name]) => name), ...SLEEP_COLUMNS.map(([name]) => name)];
  const rows = days.map((day) => {
    const all = periodsByDay.get(day) ?? [];
    const main = mainPeriod(all);
    return [
      day,
      ...DAILY_COLUMNS.map(([, metric, value]) => {
        const r = byMetric[metric]?.get(day);
        return r ? value(r) : null;
      }),
      ...SLEEP_COLUMNS.map(([, value]) => value(all, main)),
    ];
  });
  return [header, ...rows];
}

export function toCsv(rows) {
  return rows.map((row) => row.map(csvField).join(",")).join("\r\n") + "\r\n";
}

export function downloadCsv(filename, rows) {
  // The BOM lets Excel open the file as UTF-8.
  const blob = new Blob(["﻿", toCsv(rows)], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}
