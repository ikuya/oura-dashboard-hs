import { scoreColor, scoreClass, scoreLabel, formatDuration, mainPeriod } from "./helpers.js";

Chart.defaults.color = "#6b7280";
Chart.defaults.borderColor = "#2a2d3a";
Chart.defaults.font.family = '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
Chart.defaults.font.size = 12;

export const TIME_SCALE = {
  type: "time",
  time: { unit: "day", tooltipFormat: "yyyy-MM-dd" },
  adapters: { date: { zone: "UTC" } },
  grid: { color: "#2a2d3a" },
  ticks: { maxTicksLimit: 8 },
};

const LOCAL_TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;

export const TIME_SCALE_MINUTE = {
  type: "time",
  time: { unit: "hour", tooltipFormat: "yyyy-MM-dd HH:mm", displayFormats: { hour: "HH:mm" } },
  adapters: { date: { zone: LOCAL_TZ } },
  grid: { color: "#2a2d3a" },
  ticks: { maxTicksLimit: 10 },
};

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

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

export function makeChart(id, charts, config) {
  if (charts[id]) {
    charts[id].destroy();
  }
  const ctx = document.getElementById(id).getContext("2d");
  charts[id] = new Chart(ctx, withDayTooltipTitle(config));
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

// --- Personal baselines ---

// Today's card is compared with the mean of the BASELINE_DAYS before it, and
// the daily charts carry an AVERAGE_DAYS trailing mean. Both reach back past
// the selected range, so loadData() fetches that much more history.
export const BASELINE_DAYS = 28;
export const AVERAGE_DAYS = 7;

// A window this sparse (a ring left off for a week) says little about "usual".
const MIN_BASELINE_VALUES = 7;
const MIN_AVERAGE_VALUES = 4;

function addDaysStr(day, n) {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

function valuesByDay(records, value) {
  return new Map(records.flatMap((r) => {
    const v = value(r);
    return v == null ? [] : [[r.day, v]];
  }));
}

// Mean of the values on the `days` days ending at `lastDay`, or null when
// fewer than `minValues` of them have one.
function windowMean(byDay, lastDay, days, minValues) {
  const values = [];
  for (let k = 0; k < days; k++) {
    const v = byDay.get(addDaysStr(lastDay, -k));
    if (v != null) values.push(v);
  }
  return values.length < minValues ? null : values.reduce((a, b) => a + b, 0) / values.length;
}

// The trailing mean as a dashed line over the selected range. `history`
// reaches AVERAGE_DAYS before `start`, so the line is right at the left edge.
// `averageOf` ties it to the raw dataset for averageLegend().
export function averageDataset(label, history, value, color, start, averageOf, extra = {}) {
  const byDay = valuesByDay(history, value);
  return {
    type: "line",
    label: `${label} (${AVERAGE_DAYS}d avg)`,
    data: history
      .filter((r) => r.day >= start)
      .map((r) => ({ x: r.day, y: windowMean(byDay, r.day, AVERAGE_DAYS, MIN_AVERAGE_VALUES) })),
    borderColor: color + "99",
    borderDash: [6, 4],
    borderWidth: 1.5,
    pointRadius: 0,
    tension: 0.3,
    spanGaps: true,
    fill: false,
    averageOf,
    ...extra,
  };
}

// A legend that lists only the raw series and shows/hides each together with
// its average, so the averages do not double the legend.
function averageLegend(base = {}) {
  return {
    position: "top",
    ...base,
    labels: { filter: (item, data) => data.datasets[item.datasetIndex].averageOf == null },
    onClick: (_e, item, legend) => {
      const chart = legend.chart;
      const visible = !chart.isDatasetVisible(item.datasetIndex);
      chart.data.datasets.forEach((ds, i) => {
        if (i === item.datasetIndex || ds.averageOf === item.datasetIndex) {
          chart.setDatasetVisibility(i, visible);
        }
      });
      chart.update();
    },
  };
}

const neutralFormat = (v) => (v == null ? "—" : Math.round(v));

// The latest record's value, and how far it sits from the mean of the
// BASELINE_DAYS before it. `better` colours the difference: "higher", "lower",
// or null where neither direction is good (temperature deviation).
export function updateCard(prefix, records, {
  value = (r) => r.score,
  format = neutralFormat,
  formatDelta = (d) => String(Math.round(d)),
  better = "higher",
  colored = true,
  history = records,
} = {}) {
  if (!records || records.length === 0) return;
  const last = records[records.length - 1];
  const v = value(last) ?? null;
  const el = document.getElementById(`card-${prefix}`);
  const dateEl = document.getElementById(`card-${prefix}-date`);
  const deltaEl = document.getElementById(`card-${prefix}-delta`);
  if (!el) return;
  el.textContent = format(v);
  el.className = `card-value ${colored ? scoreClass(v) : "score-neutral"}`;
  const label = colored ? scoreLabel(v) : null;
  if (dateEl) dateEl.textContent = [last.day, label].filter(Boolean).join(" · ");
  if (!deltaEl) return;

  const baseline = v == null ? null
    : windowMean(valuesByDay(history, value), addDaysStr(last.day, -1), BASELINE_DAYS, MIN_BASELINE_VALUES);
  if (baseline == null) {
    deltaEl.textContent = "";
    return;
  }
  const shown = formatDelta(v - baseline);
  const zero = Number.parseFloat(shown) === 0;
  const sign = zero ? "±" : v > baseline ? "+" : "";
  const arrow = zero ? "" : v > baseline ? " ↑" : " ↓";
  const good = better === "higher" ? v > baseline : better === "lower" ? v < baseline : null;
  deltaEl.textContent = `${sign}${shown}${arrow} vs ${BASELINE_DAYS}d avg`;
  deltaEl.className = `card-delta ${zero || good == null ? "" : good ? "delta-good" : "delta-bad"}`;
}


// --- Sleep stages ---

// The Oura phase codes double as the y values of the hypnogram, which puts
// Deep at the bottom and Awake at the top, the way the Oura app draws it.
export const SLEEP_STAGES = [
  { code: 1, key: "deep",  label: "Deep",  color: "#4338ca", field: "deep_sleep_duration" },
  { code: 2, key: "light", label: "Light", color: "#38bdf8", field: "light_sleep_duration" },
  // REM was lavender, which a deuteranope confuses with Light's sky blue
  // (ΔE 5.2); magenta clears every other stage by ΔE 17+.
  { code: 3, key: "rem",   label: "REM",   color: "#d55181", field: "rem_sleep_duration" },
  { code: 4, key: "awake", label: "Awake", color: "#fbbf24", field: "awake_time" },
];

const STAGE_BY_CODE = Object.fromEntries(SLEEP_STAGES.map((s) => [s.code, s]));
const EPOCH_MS = 5 * 60 * 1000;

// `sleep_phase_5_min` is one digit per 5 minutes starting at bedtime_start.
// A stepped line holds each point's level until the next one, so a closing
// point is appended or the final epoch would not be drawn.
export function hypnogramPoints(period) {
  const phases = period?.sleep_phase_5_min;
  if (!phases) return [];
  const start = new Date(period.bedtime_start).getTime();
  const points = [];
  for (let i = 0; i < phases.length; i++) {
    const code = Number(phases[i]);
    if (STAGE_BY_CODE[code]) {
      points.push({ x: new Date(start + i * EPOCH_MS).toISOString(), y: code });
    }
  }
  if (points.length > 0) {
    points.push({
      x: new Date(start + phases.length * EPOCH_MS).toISOString(),
      y: points[points.length - 1].y,
    });
  }
  return points;
}

// --- Nightly vitals ---

const HRV_COLOR = SERIES_BLUE;
const HR_COLOR = SERIES_ORANGE;
// On the hypnogram the stage colours own the hue, so the overlays are neutral
// ink told apart by dash pattern: an orange heart rate line would sit ΔE 11.6
// from REM's magenta.
const HRV_OVERLAY = "#e2e4ed";
const HR_OVERLAY = "#9ca3af";

// A 5-minute series ({timestamp, interval, items}) as chart points. The ring
// reports null while it has no reading (typically the first half hour), which
// stays a gap rather than being bridged.
function seriesPoints(series) {
  if (!series?.timestamp || !Array.isArray(series.items)) return [];
  const start = new Date(series.timestamp).getTime();
  const step = (series.interval ?? 300) * 1000;
  return series.items.map((y, i) => ({ x: new Date(start + i * step).toISOString(), y }));
}

function vitalOverlay(label, points, color, axis, borderDash = []) {
  return {
    label,
    data: points,
    yAxisID: axis,
    borderColor: color + "b3",
    borderDash,
    borderWidth: 1.5,
    pointRadius: 0,
    tension: 0.3,
    fill: false,
  };
}

// A right-hand axis for an overlay, hidden when the period has no readings
// (most naps), so an empty axis does not eat into the plot.
function overlayAxis(title, points) {
  return {
    position: "right",
    display: points.some((p) => p.y != null),
    grid: { drawOnChartArea: false },
    title: { display: true, text: title },
  };
}

export function renderHypnogram(period, state) {
  const hrv = seriesPoints(period?.hrv);
  const hr = seriesPoints(period?.heart_rate);
  makeChart("chart-sleep-stages", state.charts, {
    type: "line",
    data: {
      datasets: [
        {
          label: "Sleep stage",
          data: hypnogramPoints(period),
          stepped: "after",
          pointRadius: 0,
          borderWidth: 2,
          borderColor: "#6b7280",
          segment: {
            borderColor: (ctx) => STAGE_BY_CODE[ctx.p0.parsed.y]?.color ?? "#6b7280",
          },
          fill: false,
        },
        vitalOverlay("HRV", hrv, HRV_OVERLAY, "yHrv"),
        vitalOverlay("Heart rate", hr, HR_OVERLAY, "yHr", [5, 4]),
      ],
    },
    options: {
      responsive: true,
      interaction: { mode: "x", intersect: false },
      scales: {
        x: TIME_SCALE_MINUTE,
        // Ticks have to land on whole phase codes for the callback to name
        // them, so the range is padded outwards rather than set to 0.5..4.5.
        y: {
          min: 0,
          max: 5,
          grid: { color: "#2a2d3a" },
          ticks: { stepSize: 1, callback: (v) => STAGE_BY_CODE[v]?.label ?? "" },
        },
        yHrv: overlayAxis("HRV (ms)", hrv),
        yHr: overlayAxis("HR (bpm)", hr),
      },
      plugins: {
        // The stages are named on the axis; the legend is for toggling the overlays.
        legend: {
          position: "top",
          labels: { filter: (item, data) => item.datasetIndex > 0 && data.datasets[item.datasetIndex].data.length > 0 },
        },
        tooltip: {
          filter: (item) => item.parsed.y != null,
          callbacks: {
            label: (ctx) => ctx.datasetIndex === 0
              ? STAGE_BY_CODE[ctx.parsed.y]?.label ?? ""
              : `${ctx.dataset.label}: ${Math.round(ctx.parsed.y)} ${ctx.dataset.yAxisID === "yHrv" ? "ms" : "bpm"}`,
          },
        },
      },
      animation: false,
    },
  });
}

// One bar per day. A day can hold several periods (a long sleep plus naps) and
// the bar is the night as a whole, so they are summed; the full bar height is
// then time_in_bed. These totals come from the duration fields rather than the
// 5-minute phase string, so they differ from the hypnogram by a few percent.
export function renderStageDurations(periods, state) {
  const byDay = new Map();
  for (const p of periods) {
    const row = byDay.get(p.day) ?? {};
    for (const s of SLEEP_STAGES) row[s.key] = (row[s.key] ?? 0) + (p[s.field] ?? 0);
    byDay.set(p.day, row);
  }
  const days = [...byDay.keys()].sort();

  makeChart("chart-sleep-stage-duration", state.charts, {
    type: "bar",
    data: {
      datasets: SLEEP_STAGES.map((s) => ({
        label: s.label,
        data: days.map((d) => ({ x: d, y: byDay.get(d)[s.key] / 3600 })),
        backgroundColor: s.color + "cc",
        borderColor: s.color,
        borderWidth: 1,
      })),
    },
    options: {
      responsive: true,
      interaction: { mode: "index", intersect: false },
      scales: {
        x: { ...TIME_SCALE, stacked: true },
        y: {
          stacked: true,
          beginAtZero: true,
          grid: { color: "#2a2d3a" },
          ticks: { callback: (v) => `${v}h` },
        },
      },
      plugins: {
        legend: { position: "top" },
        tooltip: {
          callbacks: {
            label: (ctx) =>
              `${ctx.dataset.label}: ${formatDuration(ctx.parsed.y * 3600)}`,
          },
        },
      },
    },
  });
}

// --- Bedtime / wake ---

const BEDTIME_COLOR = "#6366f1";
const WAKE_COLOR = "#fbbf24";
const NAP_COLOR = "#9ca3af";

// Hours since the noon before, on the wall clock where the period was recorded:
// 23:30 -> 11.5, 07:00 the next morning -> 19. The offset in the timestamp is
// deliberately ignored rather than converted to the browser's zone, so a night
// abroad reads as the local time it was slept. Matches clockAt in src/Advice.hs.
function wallClockHours(iso) {
  const m = /T(\d{2}):(\d{2})/.exec(iso ?? "");
  if (!m) return null;
  const h = Number(m[1]) + Number(m[2]) / 60;
  return h < 12 ? h + 24 : h;
}

function clockLabel(hours) {
  const minutes = Math.round(hours * 60);
  return `${String(Math.floor(minutes / 60) % 24).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
}

function median(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function groupByDay(periods) {
  const byDay = new Map();
  for (const p of periods) byDay.set(p.day, [...(byDay.get(p.day) ?? []), p]);
  return byDay;
}

// One row per day: the main period as the bar, the other periods as naps.
// `main` is null on a day with naps only, or whose main period's timestamps
// do not parse; such a day gets a nap marker but no bar.
export function bedtimeWakeRows(periods) {
  const byDay = groupByDay(periods);
  return [...byDay.keys()].sort().map((day) => {
    const all = byDay.get(day);
    const main = mainPeriod(all) ?? null;
    const naps = all.filter((p) => p !== main);
    const bed = wallClockHours(main?.bedtime_start);
    let wake = wallClockHours(main?.bedtime_end);
    if (bed == null || wake == null) return { day, main: null, naps };
    // Both ends are hours since noon, so the end can only come out earlier
    // when the period crosses noon; it then belongs to the next day.
    if (wake < bed) wake += 24;
    const onset = Math.min(bed + (main.latency ?? 0) / 3600, wake);
    return { day, main, bed, onset, wake, naps };
  });
}

function bedtimeWakeTooltip(row) {
  const lines = row.main ? [
    `In bed  ${clockLabel(row.bed)} – ${clockLabel(row.wake)}  (${formatDuration(row.main.time_in_bed)})`,
    `Asleep  ${clockLabel(row.onset)}  (latency ${row.main.latency == null ? "—" : formatDuration(row.main.latency)})`,
  ] : [];
  for (const n of row.naps) {
    const s = wallClockHours(n.bedtime_start);
    const e = wallClockHours(n.bedtime_end);
    if (s == null || e == null) continue;
    lines.push(`Nap  ${clockLabel(s)} – ${clockLabel(e)}  (${formatDuration(n.time_in_bed)})`);
  }
  return lines;
}

export function renderBedtimeWake(periods, state) {
  const allRows = bedtimeWakeRows(periods);
  const byDay = new Map(allRows.map((r) => [r.day, r]));
  const rows = allRows.filter((r) => r.main);

  // The axis is fitted to the main periods only; naps are marked on the top
  // edge instead of at their time, or an afternoon nap would stretch the axis
  // and squash every night.
  // The bounds are snapped to the tick step, or Chart.js adds an off-step tick
  // at each end that crowds its neighbour.
  const lo = rows.length ? Math.min(...rows.map((r) => r.bed)) - 0.5 : 21;
  const hi = rows.length ? Math.max(...rows.map((r) => r.wake)) + 0.5 : 33;
  const step = hi - lo > 12 ? 2 : 1;
  const min = Math.floor(lo / step) * step;
  const max = Math.ceil(hi / step) * step;
  const first = rows[0]?.day;
  const last = rows[rows.length - 1]?.day;
  const onsetMedian = median(rows.map((r) => r.onset));
  const wakeMedian = median(rows.map((r) => r.wake));
  const medianLine = (label, value, color) => ({
    type: "line",
    label: `${label} median ${clockLabel(value)}`,
    data: [{ x: first, y: value }, { x: last, y: value }],
    borderColor: color,
    borderDash: [6, 4],
    borderWidth: 1.5,
    pointRadius: 0,
    order: 0,
  });

  makeChart("chart-bedtime-wake", state.charts, {
    type: "bar",
    data: {
      datasets: [
        {
          label: "In bed",
          data: rows.map((r) => ({ x: r.day, y: [r.bed, r.wake] })),
          backgroundColor: BEDTIME_COLOR + "59",
          borderSkipped: false,
          grouped: false,
          order: 2,
        },
        {
          label: "Asleep",
          data: rows.map((r) => ({ x: r.day, y: [r.onset, r.wake] })),
          backgroundColor: BEDTIME_COLOR,
          borderSkipped: false,
          grouped: false,
          order: 1,
        },
        {
          type: "scatter",
          label: "Nap",
          data: allRows.filter((r) => r.naps.length > 0).map((r) => ({ x: r.day, y: min })),
          backgroundColor: NAP_COLOR,
          pointRadius: 4,
          clip: false,
          order: 0,
        },
        ...(onsetMedian == null ? [] : [
          medianLine("Sleep onset", onsetMedian, BEDTIME_COLOR),
          medianLine("Wake", wakeMedian, WAKE_COLOR),
        ]),
      ],
    },
    options: {
      responsive: true,
      interaction: { mode: "x", intersect: false },
      scales: {
        x: TIME_SCALE,
        // Reversed so time runs downwards: the night at the top, the morning below.
        y: {
          reverse: true,
          min,
          max,
          grid: { color: "#2a2d3a" },
          ticks: { stepSize: step, callback: (v) => clockLabel(v) },
        },
      },
      plugins: {
        // `order` sets the drawing order, which the legend would follow too.
        legend: { position: "top", labels: { sort: (a, b) => a.datasetIndex - b.datasetIndex } },
        tooltip: {
          // Every dataset at the hovered day says the same thing, so the bar
          // (or, failing that, the nap marker) speaks for the whole day.
          filter: (item, _i, items) =>
            item === items.find((it) => byDay.has(it.raw?.x) && it.dataset.type !== "line"),
          callbacks: {
            label: (ctx) => bedtimeWakeTooltip(byDay.get(ctx.raw.x)),
          },
        },
      },
    },
  });
}

// One point per night from the main period alone: a nap's HRV and lowest heart
// rate are not comparable with a night's (and are often missing).
export function nightlyVitalsRows(periods) {
  const byDay = groupByDay(periods);
  return [...byDay.keys()].sort().flatMap((day) => {
    const main = mainPeriod(byDay.get(day));
    return main ? [{
      day,
      hrv: main.average_hrv ?? null,
      lowest: main.lowest_heart_rate ?? null,
      average: main.average_heart_rate ?? null,
      breath: main.average_breath ?? null,
    }] : [];
  });
}

export function renderNightlyVitals(periods, historyRows, state) {
  const rows = nightlyVitalsRows(periods);
  const byDay = new Map(rows.map((r) => [r.day, r]));
  const line = (label, field, color, axis, extra = {}) => ({
    label,
    data: rows.map((r) => ({ x: r.day, y: r[field] })),
    yAxisID: axis,
    borderColor: color,
    backgroundColor: color + "22",
    pointRadius: 3,
    tension: 0.3,
    spanGaps: true,
    fill: false,
    ...extra,
  });

  makeChart("chart-nightly-vitals", state.charts, {
    type: "line",
    data: {
      datasets: [
        line("Average HRV", "hrv", HRV_COLOR, "yHrv"),
        line("Lowest HR", "lowest", HR_COLOR, "yHr"),
        line("Average HR", "average", HR_COLOR, "yHr",
             { borderDash: [2, 3], borderWidth: 1, pointRadius: 0 }),
        averageDataset("Average HRV", historyRows, (r) => r.hrv, HRV_COLOR, state.rangeStart, 0,
                       { yAxisID: "yHrv" }),
        averageDataset("Lowest HR", historyRows, (r) => r.lowest, HR_COLOR, state.rangeStart, 1,
                       { yAxisID: "yHr" }),
      ],
    },
    options: {
      responsive: true,
      interaction: { mode: "index", intersect: false },
      scales: {
        x: TIME_SCALE,
        yHrv: { position: "left", grid: { color: "#2a2d3a" }, title: { display: true, text: "HRV (ms)" } },
        yHr: { position: "right", grid: { drawOnChartArea: false }, title: { display: true, text: "HR (bpm)" } },
      },
      plugins: {
        legend: averageLegend(),
        tooltip: {
          callbacks: {
            label: (ctx) => `${ctx.dataset.label}: ${ctx.parsed.y == null ? "—" : Math.round(ctx.parsed.y)} ${ctx.dataset.yAxisID === "yHrv" ? "ms" : "bpm"}`,
            // The respiratory rate has a scale of its own (~14/min) and would
            // flatten either axis, so it is reported here rather than drawn.
            footer: (items) => {
              const breath = byDay.get(items[0]?.raw?.x)?.breath;
              return breath == null ? "" : `Breath: ${breath.toFixed(1)} /min`;
            },
          },
        },
      },
    },
  });
}

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
              return day ? `${day} (${WEEKDAYS[new Date(`${day}T00:00:00Z`).getUTCDay()]})` : "";
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

// `data` and `state.sleepPeriods` cover the selected range; `state.history`
// holds the same series reaching back far enough for the baselines.
export function renderAll(data, hrData, state) {
  const { sleep = [], readiness = [], activity = [], stress = [],
          spo2 = [], temperature = [], resilience = [],
          cardiovascular_age = [] } = data;
  const history = state.history?.metrics ?? data;
  const start = state.rangeStart;
  const past = (metric) => history[metric] ?? [];
  const score = (r) => r.score;
  // Oura reports stress_high in seconds (in 15-minute steps); the dashboard
  // shows minutes. The stored score is the same seconds value.
  const stressMinutes = (r) => {
    const seconds = r.stress_high ?? r.score;
    return seconds == null ? null : seconds / 60;
  };
  const tempDev = (r) => r.temperature_deviation ?? r.score;

  updateCard("sleep", sleep, { history: past("sleep") });
  updateCard("readiness", readiness, { history: past("readiness") });
  updateCard("activity", activity, { history: past("activity") });
  updateCard("stress", stress, {
    history: past("stress"),
    value: stressMinutes,
    format: (v) => v == null ? "—" : formatDuration(v * 60),
    formatDelta: (d) => `${Math.round(d)}m`,
    better: "lower",
    colored: false,
  });
  updateCard("spo2", spo2, {
    history: past("spo2"),
    format: (v) => v == null ? "—" : `${v.toFixed(1)}%`,
    formatDelta: (d) => d.toFixed(1),
    colored: false,
  });
  updateCard("temp", temperature, {
    history: past("temperature"),
    value: tempDev,
    format: (v) => v == null ? "—" : (v > 0 ? `+${v.toFixed(2)}` : v.toFixed(2)),
    formatDelta: (d) => d.toFixed(2),
    better: null,
    colored: false,
  });
  const vitalsHistory = nightlyVitalsRows(state.history?.sleepPeriods ?? state.sleepPeriods ?? []);
  updateCard("hrv", nightlyVitalsRows(state.sleepPeriods ?? []), {
    history: vitalsHistory,
    value: (r) => r.hrv,
    format: (v) => v == null ? "—" : `${Math.round(v)}ms`,
    colored: false,
  });

  makeChart("chart-scores", state.charts, {
    type: "line",
    data: {
      datasets: [
        lineDataset("Readiness", readiness, SERIES_AQUA),
        lineDataset("Sleep", sleep, SERIES_BLUE),
        lineDataset("Activity", activity, SERIES_ORANGE),
        averageDataset("Readiness", past("readiness"), score, SERIES_AQUA, start, 0),
        averageDataset("Sleep", past("sleep"), score, SERIES_BLUE, start, 1),
        averageDataset("Activity", past("activity"), score, SERIES_ORANGE, start, 2),
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

  renderStageDurations(state.sleepPeriods ?? [], state);
  renderBedtimeWake(state.sleepPeriods ?? [], state);
  renderNightlyVitals(state.sleepPeriods ?? [], vitalsHistory, state);
  renderBedtimeScore(state.sleepPeriods ?? [], sleep, state);
  renderWeekdayAverages([
    { label: "Readiness", records: readiness, color: SERIES_AQUA },
    { label: "Sleep", records: sleep, color: SERIES_BLUE },
    { label: "Activity", records: activity, color: SERIES_ORANGE },
  ], state);

  makeChart("chart-stress", state.charts, {
    type: "bar",
    data: {
      datasets: [{
        label: "High stress",
        data: stress.map((r) => ({ x: r.day, y: stressMinutes(r) })),
        backgroundColor: "#ef444488",
        borderColor: "#ef4444",
        borderWidth: 1,
      },
      averageDataset("High stress", past("stress"), stressMinutes, "#fca5a5", start, 0)],
    },
    options: {
      responsive: true,
      interaction: { mode: "index", intersect: false },
      scales: { x: TIME_SCALE, y: { grid: { color: "#2a2d3a" } } },
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            label: (ctx) => `${ctx.dataset.label}: ${ctx.parsed.y == null ? "—" : formatDuration(ctx.parsed.y * 60)}`,
          },
        },
      },
    },
  });

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
        averageDataset("Steps", past("activity"), (r) => r.steps, "#fcd34d", start, 0, { order: 0 }),
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

  const spo2Scores = spo2.map((r) => {
    let v = r.spo2_percentage;
    if (typeof v === "object" && v !== null) v = v.average;
    return { x: r.day, y: v ?? r.score ?? null };
  });
  makeChart("chart-spo2", state.charts, {
    type: "line",
    data: {
      datasets: [{
        label: "SpO2 (%)",
        data: spo2Scores,
        borderColor: "#38bdf8",
        backgroundColor: "#38bdf822",
        tension: 0.3,
        spanGaps: true,
        pointRadius: 3,
      }],
    },
    options: {
      responsive: true,
      scales: {
        x: TIME_SCALE,
        y: { min: 90, max: 100, grid: { color: "#2a2d3a" } },
      },
      plugins: { legend: { display: false } },
    },
  });

  makeChart("chart-temp", state.charts, {
    type: "line",
    data: {
      datasets: [{
        label: "Temp deviation (°C)",
        data: temperature.map((r) => ({ x: r.day, y: r.temperature_deviation ?? null })),
        borderColor: "#fb923c",
        backgroundColor: "#fb923c22",
        tension: 0.3,
        spanGaps: true,
        pointRadius: 3,
      }],
    },
    options: {
      responsive: true,
      scales: {
        x: TIME_SCALE,
        y: {
          grid: { color: "#2a2d3a" },
          ticks: { callback: (v) => (v > 0 ? `+${parseFloat(v.toFixed(1))}` : parseFloat(v.toFixed(1))) },
        },
      },
      plugins: {
        legend: { display: false },
        annotation: undefined,
      },
    },
  });

  makeChart("chart-hr", state.charts, {
    type: "line",
    data: {
      datasets: [{
        label: "BPM",
        data: hrData.map((r) => ({ x: r.timestamp, y: r.bpm })),
        borderColor: "#f43f5e",
        backgroundColor: "#f43f5e11",
        tension: 0.1,
        pointRadius: 0,
        borderWidth: 1.5,
      }],
    },
    options: {
      responsive: true,
      scales: {
        x: TIME_SCALE_MINUTE,
        y: { grid: { color: "#2a2d3a" } },
      },
      plugins: { legend: { display: false } },
      animation: false,
    },
  });

  const RESILIENCE_LABELS = { 1: "limited", 2: "adequate", 3: "solid", 4: "strong", 5: "exceptional" };
  makeChart("chart-resilience", state.charts, {
    type: "line",
    data: {
      datasets: [{
        label: "Resilience",
        data: resilience.map((r) => ({ x: r.day, y: r.score ?? null })),
        borderColor: "#a78bfa",
        backgroundColor: "#a78bfa22",
        tension: 0.3,
        spanGaps: true,
        pointRadius: 4,
      }],
    },
    options: {
      responsive: true,
      scales: {
        x: TIME_SCALE,
        y: {
          min: 0, max: 6,
          grid: { color: "#2a2d3a" },
          ticks: { stepSize: 1, callback: (v) => RESILIENCE_LABELS[v] || "" },
        },
      },
      plugins: { legend: { display: false } },
    },
  });

  makeChart("chart-cardio", state.charts, {
    type: "line",
    data: {
      datasets: [{
        label: "Vascular Age",
        data: cardiovascular_age.map((r) => ({ x: r.day, y: r.vascular_age ?? r.score ?? null })),
        borderColor: "#fb7185",
        backgroundColor: "#fb718522",
        tension: 0.3,
        spanGaps: true,
        pointRadius: 4,
      }],
    },
    options: {
      responsive: true,
      scales: { x: TIME_SCALE, y: { grid: { color: "#2a2d3a" } } },
      plugins: { legend: { display: false } },
    },
  });
}
