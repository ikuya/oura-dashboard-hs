import { makeChart, WEEKDAYS, SERIES_BLUE, SERIES_ORANGE, valuesByDay, dayWithWeekday } from "./common.js";
import { bedtimeWakeRows, clockLabel } from "./sleep.js";

// --- Correlations ---

// Both views follow the selected range, so 7d says little and 90d/180d is
// where they are meant to be read. The sample counts are shown for that reason.
const MIN_CORRELATION_POINTS = 7;
const WEEKDAY_ORDER = [1, 2, 3, 4, 5, 6, 0]; // Monday first, like the calendar
const isWeekend = (day) => [0, 6].includes(new Date(`${day}T00:00:00Z`).getUTCDay());

const mean = (values) => values.reduce((a, b) => a + b, 0) / values.length;

// Pearson's r and the least-squares line of y on x, or null when there are too
// few points or no spread to fit.
function linearFit(points) {
  if (points.length < MIN_CORRELATION_POINTS) return null;
  const mx = mean(points.map((p) => p.x));
  const my = mean(points.map((p) => p.y));
  const sxx = points.reduce((a, p) => a + (p.x - mx) ** 2, 0);
  const syy = points.reduce((a, p) => a + (p.y - my) ** 2, 0);
  const sxy = points.reduce((a, p) => a + (p.x - mx) * (p.y - my), 0);
  if (sxx === 0 || syy === 0) return null;
  const slope = sxy / sxx;
  return { r: sxy / Math.sqrt(sxx * syy), slope, intercept: my - slope * mx };
}

// One point per night: when the main period started (as on the Bedtime / Wake
// chart) against that day's sleep score. Both are dated by the morning, so a
// Saturday point is Friday night's sleep.
export function bedtimeScorePoints(periods, sleep) {
  const scores = valuesByDay(sleep, (r) => r.score);
  return bedtimeWakeRows(periods).flatMap((r) => {
    const score = scores.get(r.day);
    return r.main && score != null ? [{ x: r.bed, y: score, day: r.day }] : [];
  });
}

export function renderBedtimeScore(periods, sleep, state) {
  const points = bedtimeScorePoints(periods, sleep);
  const fit = linearFit(points);
  const xs = points.map((p) => p.x);
  const lo = xs.length ? Math.min(...xs) - 0.5 : 21;
  const hi = xs.length ? Math.max(...xs) + 0.5 : 27;
  const step = hi - lo > 8 ? 2 : 1;
  const min = Math.floor(lo / step) * step;
  const max = Math.ceil(hi / step) * step;

  document.getElementById("bedtime-score-note").textContent = points.length === 0 ? ""
    : fit == null ? `n=${points.length}`
    : `r = ${fit.r.toFixed(2)}, n=${points.length}`;

  const scatter = (label, color, pick) => ({
    type: "scatter",
    label,
    data: points.filter(pick),
    backgroundColor: color + "cc",
    borderColor: color,
    pointRadius: 4,
  });
  const fitAt = (x) => ({ x, y: fit.slope * x + fit.intercept });

  makeChart("chart-bedtime-score", state.charts, {
    type: "scatter",
    data: {
      datasets: [
        scatter("Weeknight", SERIES_BLUE, (p) => !isWeekend(p.day)),
        scatter("Fri / Sat night", SERIES_ORANGE, (p) => isWeekend(p.day)),
        ...(fit == null ? [] : [{
          type: "line",
          label: "Trend",
          data: [fitAt(Math.min(...xs)), fitAt(Math.max(...xs))],
          borderColor: "#9ca3af",
          borderDash: [6, 4],
          borderWidth: 1.5,
          pointRadius: 0,
        }]),
      ],
    },
    options: {
      responsive: true,
      scales: {
        x: {
          type: "linear",
          min,
          max,
          grid: { color: "#2a2d3a" },
          title: { display: true, text: "Bedtime" },
          ticks: { stepSize: step, callback: (v) => clockLabel(v) },
        },
        y: { grid: { color: "#2a2d3a" }, title: { display: true, text: "Sleep score" } },
      },
      plugins: {
        legend: { position: "top" },
        tooltip: {
          filter: (item) => item.raw?.day != null,
          callbacks: {
            title: (items) => {
              const day = items[0]?.raw?.day;
              return day ? dayWithWeekday(day) : "";
            },
            label: (ctx) => `Bed ${clockLabel(ctx.raw.x)} · Sleep ${ctx.raw.y}`,
          },
        },
      },
    },
  });
}

// Each weekday's mean per series, as the difference from the series' mean over
// the whole range: on a 0-100 axis a few points' difference would not show.
export function weekdayAverages(records, value) {
  const valued = records.flatMap((r) => {
    const v = value(r);
    return v == null ? [] : [{ dow: new Date(`${r.day}T00:00:00Z`).getUTCDay(), weekend: isWeekend(r.day), v }];
  });
  if (valued.length === 0) return null;
  const overall = mean(valued.map((e) => e.v));
  const meanOf = (es) => (es.length ? mean(es.map((e) => e.v)) : null);
  return {
    overall,
    byWeekday: WEEKDAY_ORDER.map((dow) => {
      const es = valued.filter((e) => e.dow === dow);
      return { avg: meanOf(es), n: es.length };
    }),
    weekday: meanOf(valued.filter((e) => !e.weekend)),
    weekend: meanOf(valued.filter((e) => e.weekend)),
  };
}

export function renderWeekdayAverages(series, state) {
  const stats = series.map((s) => ({ ...s, stats: weekdayAverages(s.records, (r) => r.score) }));

  // Rounded before the sign is chosen, so -0.04 reads "±0.0" rather than "−0.0".
  const signed = (d) => {
    const r = Math.round(d * 10) / 10;
    return `${r > 0 ? "+" : r < 0 ? "−" : "±"}${Math.abs(r).toFixed(1)}`;
  };
  const gaps = stats
    .filter((s) => s.stats?.weekday != null && s.stats?.weekend != null)
    .map((s) => `${s.label} ${signed(s.stats.weekend - s.stats.weekday)}`);
  document.getElementById("weekday-note").textContent =
    gaps.length ? `Weekend vs weekday: ${gaps.join(", ")}` : "";

  makeChart("chart-weekday", state.charts, {
    type: "bar",
    data: {
      labels: WEEKDAY_ORDER.map((dow) => WEEKDAYS[dow]),
      datasets: stats.map((s) => ({
        label: s.label,
        data: (s.stats?.byWeekday ?? []).map((w) => (w.avg == null ? null : w.avg - s.stats.overall)),
        backgroundColor: s.color + "cc",
        borderColor: s.color,
        borderWidth: 1,
        weekdayStats: s.stats,
      })),
    },
    options: {
      responsive: true,
      interaction: { mode: "index", intersect: false },
      scales: {
        x: { grid: { color: "#2a2d3a" } },
        y: {
          grid: { color: (ctx) => (ctx.tick.value === 0 ? "#6b7280" : "#2a2d3a") },
          title: { display: true, text: "vs range avg" },
          ticks: { callback: (v) => signed(v) },
        },
      },
      plugins: {
        legend: { position: "top" },
        tooltip: {
          filter: (item) => item.parsed.y != null,
          callbacks: {
            label: (ctx) => {
              const w = ctx.dataset.weekdayStats.byWeekday[ctx.dataIndex];
              return `${ctx.dataset.label}: ${w.avg.toFixed(1)} (${signed(ctx.parsed.y)}, n=${w.n})`;
            },
          },
        },
      },
    },
  });
}
