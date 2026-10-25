import { formatDuration, mainPeriod } from "../helpers.js";
import { makeChart, TIME_SCALE, TIME_SCALE_MINUTE, groupByDay } from "./common.js";

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

export function clockLabel(hours) {
  const minutes = Math.round(hours * 60);
  return `${String(Math.floor(minutes / 60) % 24).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
}

function median(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
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
