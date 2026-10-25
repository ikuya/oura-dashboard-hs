import { formatDuration } from "../helpers.js";
import { NARROW, makeChart, TIME_SCALE, SERIES_AQUA } from "./common.js";
import { averageDataset, averageLegend } from "./baseline.js";

// Oura reports stress_high and recovery_high in seconds (in 15-minute steps);
// the dashboard shows minutes. The stored stress score is the stress_high value.
export const stressMinutes = (r) => {
  const seconds = r.stress_high ?? r.score;
  return seconds == null ? null : seconds / 60;
};
const recoveryMinutes = (r) => (r.recovery_high == null ? null : r.recovery_high / 60);

const STRESS_COLOR = "#ef4444";
const DAY_MS = 24 * 60 * 60 * 1000;
// Tints behind the bars for Oura's day_summary; "normal" days stay plain.
const DAY_SUMMARY_TINTS = {
  stressful: { color: "#ef444426", label: "stressful" },
  restored: { color: SERIES_AQUA + "33", label: "restored" },
};

// Paints each day's column of the plot in its day_summary tint, under the
// bars and the grid.
function daySummaryBackground(summaries) {
  return {
    id: "daySummaryBackground",
    beforeDraw(chart) {
      const { ctx, chartArea, scales: { x } } = chart;
      ctx.save();
      ctx.beginPath();
      ctx.rect(chartArea.left, chartArea.top, chartArea.width, chartArea.height);
      ctx.clip();
      for (const [ms, summary] of summaries) {
        const tint = DAY_SUMMARY_TINTS[summary];
        if (!tint) continue;
        const left = x.getPixelForValue(ms - DAY_MS / 2);
        const right = x.getPixelForValue(ms + DAY_MS / 2);
        ctx.fillStyle = tint.color;
        ctx.fillRect(left, chartArea.top, right - left, chartArea.height);
      }
      ctx.restore();
    },
  };
}

function renderDaySummaryNote(id) {
  const note = document.getElementById(id);
  if (!note) return;
  note.replaceChildren("background:", ...Object.values(DAY_SUMMARY_TINTS).map(({ color, label }) => {
    const item = document.createElement("span");
    item.className = "day-summary-key";
    const swatch = document.createElement("span");
    swatch.className = "day-summary-swatch";
    swatch.style.background = color;
    item.append(swatch, label);
    return item;
  }));
}

// High-stress minutes above the axis and high-recovery minutes below it, on a
// background that marks the days Oura summarised as stressful or restored.
export function renderStressRecovery(stress, history, state) {
  const start = state.rangeStart;
  const negated = (value) => (r) => {
    const v = value(r);
    return v == null ? null : -v;
  };
  const summaries = new Map(stress.map((r) => [Date.parse(r.day), r.day_summary]));
  const minutesLabel = (v) => (v == null ? "—" : formatDuration(Math.abs(v) * 60));
  renderDaySummaryNote("stress-day-note");

  makeChart("chart-stress", state.charts, {
    type: "bar",
    data: {
      datasets: [
        {
          label: "High stress",
          data: stress.map((r) => ({ x: r.day, y: stressMinutes(r) })),
          backgroundColor: STRESS_COLOR + "88",
          borderColor: STRESS_COLOR,
          borderWidth: 1,
        },
        {
          label: "High recovery",
          data: stress.map((r) => ({ x: r.day, y: negated(recoveryMinutes)(r) })),
          backgroundColor: SERIES_AQUA + "88",
          borderColor: SERIES_AQUA,
          borderWidth: 1,
        },
        // Each average gets a stack of its own so the y stacking that puts
        // the two bars in one column does not add the lines together.
        averageDataset("High stress", history, stressMinutes, "#fca5a5", start, 0, { stack: "stress-avg" }),
        averageDataset("High recovery", history, negated(recoveryMinutes), "#6ee7b7", start, 1, { stack: "recovery-avg" }),
      ],
    },
    options: {
      responsive: true,
      interaction: { mode: "index", intersect: false },
      scales: {
        x: { ...TIME_SCALE, stacked: true },
        y: {
          stacked: true,
          grid: { color: (ctx) => (ctx.tick.value === 0 ? "#6b7280" : "#2a2d3a") },
          title: { display: !NARROW, text: "min (recovery below 0)" },
          ticks: { callback: (v) => Math.abs(v) },
        },
      },
      plugins: {
        legend: averageLegend(),
        tooltip: {
          callbacks: {
            label: (ctx) => `${ctx.dataset.label}: ${minutesLabel(ctx.parsed.y)}`,
            footer: (items) => {
              const summary = summaries.get(items[0]?.parsed?.x);
              return summary ? `Day: ${summary}` : "";
            },
          },
        },
      },
    },
    plugins: [daySummaryBackground(summaries)],
  });
}
