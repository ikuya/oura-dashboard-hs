import { scoreColor } from "../helpers.js";

// Phones (the width where .chart-row.two-col drops to one column) get smaller
// text, fewer x ticks and bare lines. Checked once, when the page loads.
export const NARROW = window.matchMedia("(max-width: 700px)").matches;

Chart.defaults.color = "#6b7280";
Chart.defaults.borderColor = "#2a2d3a";
Chart.defaults.font.family = '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
Chart.defaults.font.size = NARROW ? 11 : 12;
// Each canvas fills its .chart-box, whose height style.css sets.
Chart.defaults.maintainAspectRatio = false;

export const TIME_SCALE = {
  type: "time",
  time: { unit: "day", tooltipFormat: "yyyy-MM-dd" },
  adapters: { date: { zone: "UTC" } },
  grid: { color: "#2a2d3a" },
  ticks: { maxTicksLimit: NARROW ? 5 : 8 },
};

const LOCAL_TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;

export const TIME_SCALE_MINUTE = {
  type: "time",
  time: { unit: "hour", tooltipFormat: "yyyy-MM-dd HH:mm", displayFormats: { hour: "HH:mm" } },
  adapters: { date: { zone: LOCAL_TZ } },
  grid: { color: "#2a2d3a" },
  ticks: { maxTicksLimit: NARROW ? 6 : 10 },
};

export const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

// "2026-10-05 (Mon)". TIME_SCALE parses days as UTC midnight, so the UTC date
// is the day itself. The weekday is spelled out here rather than through
// tooltipFormat, where luxon would localise it to the browser's language.
function dayTooltipTitle(items) {
  const x = items[0]?.parsed?.x;
  if (x == null) return "";
  const d = new Date(x);
  return `${d.toISOString().slice(0, 10)} (${WEEKDAYS[d.getUTCDay()]})`;
}

// Gives every daily chart the weekday in its tooltip title, unless the chart
// sets a title of its own.
function withDayTooltipTitle(config) {
  if (config.options?.scales?.x?.time?.unit !== "day") return config;
  const plugins = config.options.plugins ?? {};
  const tooltip = plugins.tooltip ?? {};
  return {
    ...config,
    options: {
      ...config.options,
      plugins: {
        ...plugins,
        tooltip: { ...tooltip, callbacks: { title: dayTooltipTitle, ...tooltip.callbacks } },
      },
    },
  };
}

// Draws the legend as HTML chips above the chart box instead of on the
// canvas, so it takes no height from the plot and is easy to tap. Chart.js
// still builds the items (with the chart's filter and sort) and handles the
// clicks; this inline plugin runs after the built-in legend's afterUpdate.
function withHtmlLegend(config) {
  const plugins = config.options?.plugins ?? {};
  const legend = plugins.legend ?? {};
  const show = legend.display !== false;
  return {
    ...config,
    options: { ...config.options, plugins: { ...plugins, legend: { ...legend, display: false } } },
    plugins: [...(config.plugins ?? []), { id: "htmlLegend", afterUpdate: (chart) => renderHtmlLegend(chart, show) }],
  };
}

function legendContainer(canvas) {
  const box = canvas.parentElement;
  let el = box.previousElementSibling;
  if (!el?.classList.contains("chart-legend")) {
    el = document.createElement("div");
    el.className = "chart-legend";
    box.before(el);
  }
  return el;
}

function renderHtmlLegend(chart, show) {
  const el = legendContainer(chart.canvas);
  const legend = chart.legend;
  el.replaceChildren(...(show ? legend.legendItems : []).map((item) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "chart-legend-item";
    button.setAttribute("aria-pressed", String(!item.hidden));
    const swatch = document.createElement("span");
    swatch.className = "chart-legend-swatch";
    swatch.style.background = item.fillStyle;
    swatch.style.borderColor = item.strokeStyle;
    button.append(swatch, item.text);
    button.addEventListener("click", () => legend.options.onClick.call(legend, null, item, legend));
    return button;
  }));
}

// On a phone a long daily line drops its points, which would crowd into a
// solid band; they still appear on hover.
const NARROW_POINT_LIMIT = 30;

function withNarrowPoints(config) {
  if (!NARROW) return config;
  const datasets = config.data.datasets.map((ds) =>
    (ds.type ?? config.type) === "line" && ds.pointRadius > 0 && ds.data.length > NARROW_POINT_LIMIT
      ? { ...ds, pointRadius: 0 }
      : ds);
  return { ...config, data: { ...config.data, datasets } };
}

export function makeChart(id, charts, config) {
  if (charts[id]) {
    charts[id].destroy();
  }
  const ctx = document.getElementById(id).getContext("2d");
  charts[id] = new Chart(ctx, withHtmlLegend(withNarrowPoints(withDayTooltipTitle(config))));
  return charts[id];
}

// Series colours, checked with the dataviz palette validator against the card
// surface (#1a1d27) for protan / deutan / tritan separation. The previous
// green / amber / red set failed it (green vs amber: protan ΔE 5.7).
export const SERIES_BLUE = "#3987e5";
export const SERIES_ORANGE = "#d95926";
export const SERIES_AQUA = "#199e70";

// A 0-100 score series. The points keep the green / yellow / red score
// colours; the lines carry the series colour.
export function lineDataset(label, records, color, value = (r) => r.score) {
  const values = records.map((r) => value(r) ?? null);
  return {
    label,
    data: records.map((r, i) => ({ x: r.day, y: values[i] })),
    borderColor: color,
    backgroundColor: color + "22",
    pointBackgroundColor: values.map(scoreColor),
    pointRadius: 3,
    tension: 0.3,
    spanGaps: true,
    fill: false,
  };
}

export function addDaysStr(day, n) {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export function valuesByDay(records, value) {
  return new Map(records.flatMap((r) => {
    const v = value(r);
    return v == null ? [] : [[r.day, v]];
  }));
}

export function groupByDay(periods) {
  const byDay = new Map();
  for (const p of periods) byDay.set(p.day, [...(byDay.get(p.day) ?? []), p]);
  return byDay;
}

export const dayWithWeekday = (day) => `${day} (${WEEKDAYS[new Date(`${day}T00:00:00Z`).getUTCDay()]})`;
