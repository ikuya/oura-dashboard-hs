import { scoreColor, scoreClass, formatDuration, mainPeriod } from "./helpers.js";

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

export function lineDataset(label, records, color, yField = "score") {
  return {
    label,
    data: records.map((r) => ({ x: r.day, y: r[yField] ?? null })),
    borderColor: color,
    backgroundColor: color + "22",
    pointBackgroundColor: records.map((r) => scoreColor(r[yField])),
    pointRadius: 3,
    tension: 0.3,
    spanGaps: true,
    fill: false,
  };
}

export function updateCard(prefix, records, valueField = "score", formatter = (v) => v == null ? "—" : Math.round(v)) {
  if (!records || records.length === 0) return;
  const last = records[records.length - 1];
  const v = last[valueField] ?? last.score ?? null;
  const el = document.getElementById(`card-${prefix}`);
  const dateEl = document.getElementById(`card-${prefix}-date`);
  if (!el) return;
  el.textContent = formatter(v);
  el.className = `card-value ${scoreClass(v)}`;
  if (dateEl) dateEl.textContent = last.day || "";
}


// --- Sleep stages ---

// The Oura phase codes double as the y values of the hypnogram, which puts
// Deep at the bottom and Awake at the top, the way the Oura app draws it.
export const SLEEP_STAGES = [
  { code: 1, key: "deep",  label: "Deep",  color: "#4338ca", field: "deep_sleep_duration" },
  { code: 2, key: "light", label: "Light", color: "#38bdf8", field: "light_sleep_duration" },
  { code: 3, key: "rem",   label: "REM",   color: "#a78bfa", field: "rem_sleep_duration" },
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

export function renderHypnogram(period, state) {
  makeChart("chart-sleep-stages", state.charts, {
    type: "line",
    data: {
      datasets: [{
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
      }],
    },
    options: {
      responsive: true,
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
      },
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: { label: (ctx) => STAGE_BY_CODE[ctx.parsed.y]?.label ?? "" },
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

// One row per day: the main period as the bar, the other periods as naps.
// `main` is null on a day with naps only, or whose main period's timestamps
// do not parse; such a day gets a nap marker but no bar.
export function bedtimeWakeRows(periods) {
  const byDay = new Map();
  for (const p of periods) byDay.set(p.day, [...(byDay.get(p.day) ?? []), p]);
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

export function renderAll(data, hrData, state) {
  const { sleep = [], readiness = [], activity = [], stress = [],
          spo2 = [], temperature = [], resilience = [],
          cardiovascular_age = [] } = data;

  updateCard("sleep", sleep);
  updateCard("readiness", readiness);
  updateCard("activity", activity);
  updateCard("stress", stress, "stress_high",
    (v) => v == null ? "—" : `${Math.round(v)}m`);
  updateCard("spo2", spo2, "score",
    (v) => v == null ? "—" : `${v.toFixed(1)}%`);
  updateCard("temp", temperature, "temperature_deviation",
    (v) => v == null ? "—" : (v > 0 ? `+${v.toFixed(2)}` : v.toFixed(2)));

  makeChart("chart-scores", state.charts, {
    type: "line",
    data: {
      datasets: [
        lineDataset("Readiness", readiness, "#22c55e"),
        lineDataset("Sleep", sleep, "#6366f1"),
        lineDataset("Activity", activity, "#f59e0b"),
      ],
    },
    options: {
      responsive: true,
      interaction: { mode: "index", intersect: false },
      scales: {
        x: TIME_SCALE,
        y: { min: 0, max: 100, grid: { color: "#2a2d3a" } },
      },
      plugins: { legend: { position: "top" } },
    },
  });

  makeChart("chart-sleep-restfulness-efficiency", state.charts, {
    type: "line",
    data: {
      datasets: [
        {
          label: "Restfulness",
          data: sleep.map((r) => ({ x: r.day, y: r.contributors?.restfulness ?? null })),
          borderColor: "#818cf8",
          backgroundColor: "#818cf822",
          pointBackgroundColor: sleep.map((r) => scoreColor(r.contributors?.restfulness)),
          pointRadius: 3,
          tension: 0.3,
          spanGaps: true,
          fill: false,
        },
        {
          label: "Efficiency",
          data: sleep.map((r) => ({ x: r.day, y: r.contributors?.efficiency ?? null })),
          borderColor: "#34d399",
          backgroundColor: "#34d39922",
          pointBackgroundColor: sleep.map((r) => scoreColor(r.contributors?.efficiency)),
          pointRadius: 3,
          tension: 0.3,
          spanGaps: true,
          fill: false,
        },
        {
          label: "Sleep Balance",
          data: readiness.map((r) => ({ x: r.day, y: r.contributors?.sleep_balance ?? null })),
          borderColor: "#fb923c",
          backgroundColor: "#fb923c22",
          pointBackgroundColor: readiness.map((r) => scoreColor(r.contributors?.sleep_balance)),
          pointRadius: 3,
          tension: 0.3,
          spanGaps: true,
          fill: false,
        },
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

  makeChart("chart-stress", state.charts, {
    type: "bar",
    data: {
      datasets: [{
        label: "High stress (min)",
        data: stress.map((r) => ({ x: r.day, y: r.stress_high ?? null })),
        backgroundColor: "#ef444488",
        borderColor: "#ef4444",
        borderWidth: 1,
      }],
    },
    options: {
      responsive: true,
      scales: { x: TIME_SCALE, y: { grid: { color: "#2a2d3a" } } },
      plugins: { legend: { display: false } },
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
      ],
    },
    options: {
      responsive: true,
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
              ctx.datasetIndex === 0
                ? `Steps: ${ctx.parsed.y?.toLocaleString() ?? "—"}`
                : "Goal: 8,000",
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
