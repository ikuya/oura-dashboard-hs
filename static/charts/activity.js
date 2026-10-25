import { formatDuration } from "../helpers.js";
import { NARROW, makeChart, TIME_SCALE, SERIES_ORANGE } from "./common.js";
import { averageDataset, averageLegend } from "./baseline.js";

// Oura reports the activity times in seconds. Intensity runs low -> high as
// the orange deepens, bottom to top of each bar.
const ACTIVITY_INTENSITIES = [
  { key: "low_activity_time", label: "Low", color: SERIES_ORANGE + "55" },
  { key: "medium_activity_time", label: "Medium", color: SERIES_ORANGE + "aa" },
  { key: "high_activity_time", label: "High", color: SERIES_ORANGE },
];
const SEDENTARY_COLOR = "#9ca3af";
const ALERT_COLOR = "#ef4444";
const sedentaryHours = (r) => (r.sedentary_time == null ? null : r.sedentary_time / 3600);

// Minutes at each intensity stacked as bars, with the sedentary time as a line
// on an hours axis of its own (it runs ~10h against ~3h of activity) and the
// days Oura sent inactivity alerts marked on that line.
export function renderActivityBreakdown(activity, history, state) {
  const byDay = new Map(activity.map((r) => [r.day, r]));

  makeChart("chart-activity-breakdown", state.charts, {
    type: "bar",
    data: {
      datasets: [
        ...ACTIVITY_INTENSITIES.map(({ key, label, color }) => ({
          label,
          data: activity.map((r) => ({ x: r.day, y: r[key] == null ? null : r[key] / 60 })),
          backgroundColor: color,
          borderColor: SERIES_ORANGE,
          borderWidth: 1,
          yAxisID: "yActive",
          stack: "active",
          order: 2,
        })),
        {
          type: "line",
          label: "Sedentary",
          data: activity.map((r) => ({ x: r.day, y: sedentaryHours(r) })),
          yAxisID: "ySedentary",
          borderColor: SEDENTARY_COLOR,
          backgroundColor: SEDENTARY_COLOR + "22",
          pointRadius: 3,
          tension: 0.3,
          spanGaps: true,
          fill: false,
          order: 1,
        },
        {
          type: "line",
          label: "Inactivity alerts",
          // One entry per day, null where there was no alert: the "index"
          // tooltip lines the datasets up by index, and this one wins ties.
          data: activity.map((r) => ({
            x: r.day,
            y: (r.inactivity_alerts ?? 0) > 0 ? sedentaryHours(r) : null,
          })),
          yAxisID: "ySedentary",
          showLine: false,
          pointStyle: "triangle",
          pointRadius: 6,
          pointHoverRadius: 7,
          borderColor: ALERT_COLOR,
          backgroundColor: ALERT_COLOR,
          order: 0,
        },
        averageDataset("Sedentary", history, sedentaryHours, SEDENTARY_COLOR, state.rangeStart, 3,
                       { yAxisID: "ySedentary", order: 1 }),
      ],
    },
    options: {
      responsive: true,
      interaction: { mode: "index", intersect: false },
      scales: {
        x: { ...TIME_SCALE, stacked: true },
        yActive: {
          position: "left",
          stacked: true,
          beginAtZero: true,
          grid: { color: "#2a2d3a" },
          title: { display: !NARROW, text: "active (min)" },
        },
        ySedentary: {
          position: "right",
          beginAtZero: true,
          grid: { drawOnChartArea: false },
          title: { display: !NARROW, text: "sedentary (h)" },
        },
      },
      plugins: {
        legend: averageLegend(),
        tooltip: {
          // The alert marker repeats the sedentary value; the footer names it.
          filter: (item) => item.dataset.label !== "Inactivity alerts",
          callbacks: {
            label: (ctx) => {
              const y = ctx.parsed.y;
              const seconds = y == null ? null : y * (ctx.dataset.yAxisID === "yActive" ? 60 : 3600);
              return `${ctx.dataset.label}: ${formatDuration(seconds)}`;
            },
            footer: (items) => {
              const r = byDay.get(items[0]?.raw?.x);
              if (!r) return "";
              const lines = [];
              if (r.active_calories != null) lines.push(`Active calories: ${r.active_calories} kcal`);
              if (r.inactivity_alerts != null) lines.push(`Inactivity alerts: ${r.inactivity_alerts}`);
              return lines;
            },
          },
        },
      },
    },
  });
}

export function renderSteps(activity, history, state) {
  makeChart("chart-steps", state.charts, {
    type: "bar",
    data: {
      datasets: [
        {
          label: "Steps",
          data: activity.map((r) => ({ x: r.day, y: r.steps ?? null })),
          backgroundColor: "#f59e0b88",
          borderColor: "#f59e0b",
          borderWidth: 1,
          order: 2,
        },
        {
          label: "Goal (8,000)",
          data: activity.map((r) => ({ x: r.day, y: 8000 })),
          type: "line",
          borderColor: "#6b728088",
          borderDash: [4, 4],
          borderWidth: 1.5,
          pointRadius: 0,
          backgroundColor: "transparent",
          order: 1,
        },
        averageDataset("Steps", history, (r) => r.steps, "#fcd34d", state.rangeStart, 0, { order: 0 }),
      ],
    },
    options: {
      responsive: true,
      interaction: { mode: "index", intersect: false },
      scales: {
        x: TIME_SCALE,
        y: {
          beginAtZero: true,
          grid: { color: "#2a2d3a" },
          ticks: { callback: (v) => v >= 1000 ? `${v / 1000}k` : v },
        },
      },
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            label: (ctx) =>
              ctx.datasetIndex === 1
                ? "Goal: 8,000"
                : `${ctx.dataset.label}: ${ctx.parsed.y == null ? "—" : Math.round(ctx.parsed.y).toLocaleString()}`,
          },
        },
      },
    },
  });
}
