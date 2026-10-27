import { makeChart, TIME_SCALE, SERIES_BLUE, SERIES_ORANGE, SERIES_AQUA, lineDataset, rangeDays, dayWithWeekday } from "./common.js";
import { averageDataset, averageLegend } from "./baseline.js";

// --- Score contributors ---

// The parts Oura scores 0-100 and builds the Readiness and Sleep scores from,
// in the order the Oura app lists them. `short` fits the score card.
export const READINESS_CONTRIBUTORS = [
  { key: "resting_heart_rate",    label: "Resting HR",         short: "Resting HR" },
  { key: "hrv_balance",           label: "HRV balance",        short: "HRV bal." },
  { key: "body_temperature",      label: "Body temperature",   short: "Body temp" },
  { key: "recovery_index",        label: "Recovery index",     short: "Recovery" },
  { key: "previous_night",        label: "Previous night",     short: "Prev. night" },
  { key: "sleep_balance",         label: "Sleep balance",      short: "Sleep bal." },
  { key: "sleep_regularity",      label: "Sleep regularity",   short: "Regularity" },
  { key: "previous_day_activity", label: "Previous day act.",  short: "Prev. day act." },
  { key: "activity_balance",      label: "Activity balance",   short: "Act. bal." },
];

export const SLEEP_CONTRIBUTORS = [
  { key: "total_sleep", label: "Total sleep", short: "Total" },
  { key: "efficiency",  label: "Efficiency",  short: "Efficiency" },
  { key: "restfulness", label: "Restfulness", short: "Restfulness" },
  { key: "rem_sleep",   label: "REM sleep",   short: "REM" },
  { key: "deep_sleep",  label: "Deep sleep",  short: "Deep" },
  { key: "latency",     label: "Latency",     short: "Latency" },
  { key: "timing",      label: "Timing",      short: "Timing" },
];

const DRAG_COUNT = 2;

// The record's lowest contributors, the ones that pulled its score down most.
// Ties keep the list order.
export function lowestContributors(record, contributors, count = DRAG_COUNT) {
  const values = record?.contributors ?? {};
  return contributors
    .map((c) => ({ ...c, value: values[c.key] }))
    .filter((c) => c.value != null)
    .sort((a, b) => a.value - b.value)
    .slice(0, count);
}


// A cell's shade is how far the contributor fell short of 100, so the days
// and parts that pulled the score down are the ones that stand out; at
// HEATMAP_FLOOR and below it is at full strength. One hue (the baseline
// delta's "worse"), faded towards the card surface.
const HEATMAP_RGB = [232, 116, 59];
const HEATMAP_FLOOR = 50;
const HEATMAP_MIN_ALPHA = 0.15;

function heatmapColor(value) {
  const shortfall = Math.min(Math.max((100 - value) / (100 - HEATMAP_FLOOR), 0), 1);
  const alpha = HEATMAP_MIN_ALPHA + (1 - HEATMAP_MIN_ALPHA) * shortfall;
  return `rgba(${HEATMAP_RGB.join(", ")}, ${alpha.toFixed(3)})`;
}

// Rows are the contributors, columns every day of the range (blank where the
// day has no record). Pointing at or tapping a cell names it below the grid.
export function renderContributorHeatmap(id, records, contributors, state) {
  const box = document.getElementById(id);
  const detail = document.getElementById(`${id}-detail`);
  if (!box || !state.rangeStart || !state.rangeEnd) return;
  const days = rangeDays(state.rangeStart, state.rangeEnd);
  const byDay = new Map(records.map((r) => [r.day, r.contributors ?? {}]));
  // The 2px surface gap between cells eats a 180-day range, so it narrows.
  const gap = days.length <= 31 ? 2 : days.length <= 90 ? 1 : 0;

  const grid = document.createElement("div");
  grid.className = "heatmap-grid";
  grid.style.gridTemplateColumns = `var(--heatmap-label-width) repeat(${days.length}, minmax(0, 1fr))`;
  grid.style.gridTemplateRows = `repeat(${contributors.length}, minmax(0, 1fr)) auto`;
  grid.style.gap = `${gap}px`;

  for (const c of contributors) {
    const label = document.createElement("div");
    label.className = "heatmap-label";
    label.textContent = c.label;
    grid.append(label);
    for (const day of days) {
      const value = byDay.get(day)?.[c.key];
      const cell = document.createElement("div");
      cell.className = "heatmap-cell";
      cell.dataset.text = `${dayWithWeekday(day)} · ${c.label} ${value ?? "—"}`;
      if (value != null) cell.style.background = heatmapColor(value);
      grid.append(cell);
    }
  }

  const axis = document.createElement("div");
  axis.className = "heatmap-axis";
  axis.style.gridColumn = "2 / -1";
  const mid = days[Math.floor((days.length - 1) / 2)];
  axis.append(...[days[0], mid, days[days.length - 1]].map((day) => {
    const tick = document.createElement("span");
    tick.textContent = day.slice(5);
    return tick;
  }));
  grid.append(document.createElement("div"), axis);

  let selected = null;
  const select = (e) => {
    const cell = e.target.closest(".heatmap-cell");
    if (!cell || cell === selected) return;
    selected?.classList.remove("selected");
    cell.classList.add("selected");
    selected = cell;
    if (detail) detail.textContent = cell.dataset.text;
  };
  grid.addEventListener("pointerover", select);
  grid.addEventListener("click", select);

  box.replaceChildren(grid);
  if (detail) detail.textContent = "Tap a cell for its value";

  const legend = box.parentElement.querySelector(".heatmap-legend");
  if (legend && !legend.hasChildNodes()) {
    const swatch = (value) => {
      const s = document.createElement("span");
      s.className = "heatmap-swatch";
      s.style.background = heatmapColor(value);
      return s;
    };
    const text = (t) => Object.assign(document.createElement("span"), { textContent: t });
    legend.append(text("100"), ...[100, 88, 75, 63, HEATMAP_FLOOR].map(swatch),
                  text(`≤${HEATMAP_FLOOR}`), text("· blank = no data"));
  }
}

// --- Score trends ---

export function renderScores(readiness, sleep, activity, history, state) {
  const start = state.rangeStart;
  const score = (r) => r.score;
  makeChart("chart-scores", state.charts, {
    type: "line",
    data: {
      datasets: [
        lineDataset("Readiness", readiness, SERIES_AQUA),
        lineDataset("Sleep", sleep, SERIES_BLUE),
        lineDataset("Activity", activity, SERIES_ORANGE),
        averageDataset("Readiness", history.readiness ?? [], score, SERIES_AQUA, start, 0),
        averageDataset("Sleep", history.sleep ?? [], score, SERIES_BLUE, start, 1),
        averageDataset("Activity", history.activity ?? [], score, SERIES_ORANGE, start, 2),
      ],
    },
    options: {
      responsive: true,
      interaction: { mode: "index", intersect: false },
      scales: {
        x: TIME_SCALE,
        y: { min: 0, max: 100, grid: { color: "#2a2d3a" } },
      },
      plugins: { legend: averageLegend() },
    },
  });
}

export function renderSleepQuality(sleep, readiness, state) {
  makeChart("chart-sleep-restfulness-efficiency", state.charts, {
    type: "line",
    data: {
      datasets: [
        lineDataset("Restfulness", sleep, SERIES_BLUE, (r) => r.contributors?.restfulness),
        lineDataset("Efficiency", sleep, SERIES_AQUA, (r) => r.contributors?.efficiency),
        lineDataset("Sleep Balance", readiness, SERIES_ORANGE, (r) => r.contributors?.sleep_balance),
      ],
    },
    options: {
      responsive: true,
      interaction: { mode: "index", intersect: false },
      scales: {
        x: TIME_SCALE,
        y: { min: 0, max: 100, grid: { color: "#2a2d3a" } },
      },
      plugins: { legend: { display: true, position: "top" } },
    },
  });
}
