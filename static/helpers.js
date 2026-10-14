export function localDateStr(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

export function todayStr() {
  return localDateStr();
}

export function daysAgoStr(n) {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return localDateStr(d);
}

export function scoreColor(v) {
  if (v == null) return "#6b7280";
  if (v >= 80) return "#22c55e";
  if (v >= 60) return "#eab308";
  return "#ef4444";
}

// The band scoreColor / scoreClass paint, spelled out so the card does not
// rest on telling green, yellow and red apart.
export function scoreLabel(v) {
  if (v == null) return null;
  if (v >= 80) return "Good";
  if (v >= 60) return "Fair";
  return "Low";
}

export function scoreClass(v) {
  if (v == null) return "score-neutral";
  if (v >= 80) return "score-green";
  if (v >= 60) return "score-yellow";
  return "score-red";
}

export function setStatus(msg, isError = false) {
  const el = document.getElementById("status-bar");
  el.textContent = msg;
  el.className = isError ? "error" : "";
}

// Seconds as "7h 4m" / "34m". Used by the sleep stage tooltips and tabs.
export function formatDuration(seconds) {
  if (seconds == null) return "—";
  const h = Math.floor(seconds / 3600);
  const m = Math.round((seconds % 3600) / 60);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

// The long sleep if the night has one, otherwise its longest period (the first
// of equals). A late nap is never the night's sleep, so a day holding nothing
// else has no main period and this returns undefined. Mirrors mainSleepPeriod
// in src/Advice.hs.
export function mainPeriod(periods) {
  const candidates = periods.filter((p) => p.type !== "late_nap");
  return candidates.find((p) => p.type === "long_sleep")
    ?? candidates.reduce(
         (a, b) => ((b.time_in_bed ?? 0) > (a.time_in_bed ?? 0) ? b : a),
         candidates[0]);
}

// cron syncs at 11:00, 17:00 and 23:00, so the longest normal gap is the 12
// hours overnight. Past STALE_HOURS at least one run has been missed; past
// VERY_STALE_HOURS the data is a day or more behind.
export const STALE_HOURS = 13;
export const VERY_STALE_HOURS = 25;

// Judged on the metric that synced longest ago: a sync that keeps failing for
// one endpoint leaves the others fresh, and that is exactly the case to flag.
// Metrics never synced are left out unless nothing has synced at all.
export function syncFreshness(status, now = new Date()) {
  const synced = Object.entries(status)
    .filter(([, v]) => v.last_synced_at)
    .map(([metric, v]) => ({ metric, at: new Date(v.last_synced_at) }));
  if (synced.length === 0) return { level: "very-stale", oldest: null, lagging: [] };

  const hoursAgo = (at) => (now - at) / 3_600_000;
  const oldest = synced.reduce((a, b) => (b.at < a.at ? b : a));
  const hours = hoursAgo(oldest.at);
  const level = hours > VERY_STALE_HOURS ? "very-stale" : hours > STALE_HOURS ? "stale" : "fresh";
  const lagging = synced.filter((s) => hoursAgo(s.at) > STALE_HOURS).map((s) => s.metric);
  return { level, oldest: oldest.at, hours, lagging };
}

export function formatAge(hours) {
  if (hours < 1) return `${Math.max(1, Math.round(hours * 60))}m`;
  if (hours < 48) return `${Math.round(hours)}h`;
  return `${Math.round(hours / 24)}d`;
}
