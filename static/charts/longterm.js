import { NARROW, makeChart, TIME_SCALE, SERIES_BLUE, SERIES_ORANGE, SERIES_AQUA } from "./common.js";

// --- Monthly averages over the whole history ---

// /api/monthly gives each series as [{month: "2024-05", mean, days}], over
// every stored day. Unlike the other charts this one ignores the selected
// range: its point is the years of data the presets cannot reach.

// A month with fewer days than this (the current month, or a gap in wearing
// the ring) is drawn as a hollow point: its mean rests on little.
const THIN_MONTH_DAYS = 10;

const STRESS_COLOR = "#ef4444";

const MONTHLY_VIEWS = [
  { key: "scores", label: "Scores", series: [
    { key: "readiness", label: "Readiness", color: SERIES_AQUA, axis: "y" },
    { key: "sleep", label: "Sleep", color: SERIES_BLUE, axis: "y" },
    { key: "activity", label: "Activity", color: SERIES_ORANGE, axis: "y" },
  ], axes: { y: { title: "Score" } } },
  { key: "vitals", label: "HRV / HR", series: [
    { key: "average_hrv", label: "Average HRV", color: SERIES_BLUE, axis: "y", unit: "ms" },
    { key: "lowest_heart_rate", label: "Lowest HR", color: SERIES_ORANGE, axis: "yHr", unit: "bpm" },
  ], axes: { y: { title: "HRV (ms)" }, yHr: { title: "Lowest HR (bpm)", right: true } } },
  { key: "steps", label: "Steps", series: [
    { key: "steps", label: "Steps", color: SERIES_ORANGE, axis: "y", digits: 0 },
  ], axes: { y: { title: "Steps / day" } } },
  { key: "stress", label: "Stress", series: [
    // Stored in seconds, shown in minutes like the daily Stress chart.
    { key: "stress_high", label: "High stress", color: STRESS_COLOR, axis: "y", unit: "min", scale: 1 / 60 },
  ], axes: { y: { title: "High stress (min / day)" } } },
];

const MONTH_SCALE = {
  ...TIME_SCALE,
  time: { unit: "month", tooltipFormat: "yyyy-MM" },
  ticks: { maxTicksLimit: NARROW ? 5 : 10 },
};

function monthlyDataset(s, rows) {
  const scale = s.scale ?? 1;
  const points = rows.map((r) => ({ x: `${r.month}-01`, y: r.mean == null ? null : r.mean * scale, days: r.days }));
  return {
    label: s.label,
    data: points,
    yAxisID: s.axis,
    borderColor: s.color,
    backgroundColor: s.color + "22",
    pointBackgroundColor: points.map((p) => (p.days < THIN_MONTH_DAYS ? "transparent" : s.color)),
    pointBorderColor: s.color,
    pointRadius: 3,
    tension: 0.3,
    // A month with no data at all stays a gap rather than being bridged.
    spanGaps: false,
    fill: false,
    monthlySeries: s,
  };
}

// Months missing from a series (before it was tracked, or without the ring)
// as nulls, so the line breaks there instead of joining across.
function withGaps(rows, months) {
  const byMonth = new Map(rows.map((r) => [r.month, r]));
  return months.map((m) => byMonth.get(m) ?? { month: m, mean: null, days: 0 });
}

function monthsBetween(first, last) {
  const months = [];
  let [y, m] = first.split("-").map(Number);
  for (let key = first; key <= last; key = `${y}-${String(m).padStart(2, "0")}`) {
    months.push(key);
    m += 1;
    if (m > 12) { m = 1; y += 1; }
  }
  return months;
}

function formatValue(s, v) {
  const digits = s.digits ?? 1;
  const text = v.toLocaleString(undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits });
  return s.unit ? `${text} ${s.unit}` : text;
}

function renderViewButtons(selected, onPick) {
  document.getElementById("monthly-views").replaceChildren(...MONTHLY_VIEWS.map((v) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `chart-mode-btn${v.key === selected ? " active" : ""}`;
    button.textContent = v.label;
    button.addEventListener("click", () => onPick(v.key));
    return button;
  }));
}

export function renderMonthly(monthly, state) {
  const view = MONTHLY_VIEWS.find((v) => v.key === state.monthlyView) ?? MONTHLY_VIEWS[0];
  renderViewButtons(view.key, (key) => {
    state.monthlyView = key;
    renderMonthly(monthly, state);
  });

  const seriesRows = view.series.map((s) => monthly?.[s.key] ?? []);
  const present = seriesRows.flat().map((r) => r.month).sort();
  const months = present.length ? monthsBetween(present[0], present[present.length - 1]) : [];
  document.getElementById("monthly-note").textContent = months.length
    ? `${months[0]} – ${months[months.length - 1]}` : "";

  const axis = ({ title, right }) => ({
    position: right ? "right" : "left",
    grid: right ? { drawOnChartArea: false } : { color: "#2a2d3a" },
    title: { display: true, text: title },
  });

  makeChart("chart-monthly", state.charts, {
    type: "line",
    data: {
      datasets: view.series.map((s, i) => monthlyDataset(s, withGaps(seriesRows[i], months))),
    },
    options: {
      responsive: true,
      interaction: { mode: "index", intersect: false },
      scales: {
        x: MONTH_SCALE,
        ...Object.fromEntries(Object.entries(view.axes).map(([id, a]) => [id, axis(a)])),
      },
      plugins: {
        legend: { position: "top" },
        tooltip: {
          filter: (item) => item.parsed.y != null,
          callbacks: {
            label: (ctx) => {
              const s = ctx.dataset.monthlySeries;
              return `${s.label}: ${formatValue(s, ctx.parsed.y)} (${ctx.raw.days} days)`;
            },
          },
        },
      },
    },
  });
}
