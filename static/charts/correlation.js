import { makeChart, WEEKDAYS, SERIES_BLUE, SERIES_ORANGE, SERIES_AQUA,
         valuesByDay, dayWithWeekday, addDaysStr } from "./common.js";
import { bedtimeWakeRows, clockLabel } from "./sleep.js";
import { nightlyVitalsRows } from "./vitals.js";
import { stressMinutes } from "./stress.js";

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

// A linear x axis of clock times fitted to the points' bedtimes, with the
// bounds snapped to the tick step.
function clockScale(xs) {
  const lo = xs.length ? Math.min(...xs) - 0.5 : 21;
  const hi = xs.length ? Math.max(...xs) + 0.5 : 27;
  const step = hi - lo > 8 ? 2 : 1;
  return {
    type: "linear",
    min: Math.floor(lo / step) * step,
    max: Math.ceil(hi / step) * step,
    grid: { color: "#2a2d3a" },
    title: { display: true, text: "Bedtime" },
    ticks: { stepSize: step, callback: (v) => clockLabel(v) },
  };
}

// The fitted line across the points' x range, as a dashed grey segment.
function trendDataset(fit, xs) {
  const at = (x) => ({ x, y: fit.slope * x + fit.intercept });
  return {
    type: "line",
    label: "Trend",
    data: [at(Math.min(...xs)), at(Math.max(...xs))],
    borderColor: "#9ca3af",
    borderDash: [6, 4],
    borderWidth: 1.5,
    pointRadius: 0,
  };
}

const fitNote = (points, fit) => (points.length === 0 ? ""
  : fit == null ? `n=${points.length}`
  : `r = ${fit.r.toFixed(2)}, n=${points.length}`);

export function renderBedtimeScore(periods, sleep, state) {
  const points = bedtimeScorePoints(periods, sleep);
  const fit = linearFit(points);
  const xs = points.map((p) => p.x);

  document.getElementById("bedtime-score-note").textContent = fitNote(points, fit);

  const scatter = (label, color, pick) => ({
    type: "scatter",
    label,
    data: points.filter(pick),
    backgroundColor: color + "cc",
    borderColor: color,
    pointRadius: 4,
  });

  makeChart("chart-bedtime-score", state.charts, {
    type: "scatter",
    data: {
      datasets: [
        scatter("Weeknight", SERIES_BLUE, (p) => !isWeekend(p.day)),
        scatter("Fri / Sat night", SERIES_ORANGE, (p) => isWeekend(p.day)),
        ...(fit == null ? [] : [trendDataset(fit, xs)]),
      ],
    },
    options: {
      responsive: true,
      scales: {
        x: clockScale(xs),
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

// --- Next-day effects ---

// What a day held against how the next morning came out. Activity and stress
// are daytime totals, so day D's value meets day D+1's readiness and night.
// A bedtime row is already dated by the morning its night ends in, so it
// meets that same day. `causeDay` is the day the cause belongs to either way.
const minutesOf = (seconds) => (seconds == null ? null : seconds / 60);
const NEXT_DAY_CAUSES = [
  { key: "steps", label: "Steps", axis: "Steps (day before)",
    byDay: ({ metrics }) => shiftedValues(metrics.activity, (r) => r.steps),
    format: (v) => Math.round(v).toLocaleString() },
  { key: "active", label: "Med+High", axis: "Medium + high activity, min (day before)",
    byDay: ({ metrics }) => shiftedValues(metrics.activity, (r) =>
      r.medium_activity_time == null || r.high_activity_time == null ? null
        : minutesOf(r.medium_activity_time + r.high_activity_time)),
    format: (v) => `${Math.round(v)} min` },
  { key: "stress", label: "High stress", axis: "High stress, min (day before)",
    byDay: ({ metrics }) => shiftedValues(metrics.stress, stressMinutes),
    format: (v) => `${Math.round(v)} min` },
  { key: "bedtime", label: "Bedtime", axis: "Bedtime (night before)", clock: true,
    byDay: ({ periods }) => new Map(bedtimeWakeRows(periods).flatMap((r) =>
      r.main ? [[r.day, { x: r.bed, causeDay: addDaysStr(r.day, -1) }]] : [])),
    format: clockLabel },
];

const NEXT_DAY_OUTCOMES = [
  { key: "readiness", label: "Readiness", axis: "Readiness", color: SERIES_AQUA,
    byDay: ({ metrics }) => valuesByDay(metrics.readiness ?? [], (r) => r.score),
    format: (v) => String(v) },
  { key: "hrv", label: "Night HRV", axis: "Average HRV (ms)", color: SERIES_BLUE,
    byDay: ({ periods }) => valuesByDay(nightlyVitalsRows(periods), (r) => r.hrv),
    format: (v) => `${v} ms` },
];

// Daily values keyed by the following day, the one whose morning they meet.
function shiftedValues(records, value) {
  return new Map([...valuesByDay(records ?? [], value)].map(([day, x]) =>
    [addDaysStr(day, 1), { x, causeDay: day }]));
}

// One point per morning in the range that has both the outcome and the cause.
// The causes come from `source`, which reaches back past the range, so the
// range's first morning still gets the day before it.
export function nextDayPoints(source, cause, outcome, rangeStart) {
  const causes = cause.byDay(source);
  return [...outcome.byDay(source)].flatMap(([day, y]) => {
    const c = causes.get(day);
    return c && (rangeStart == null || day >= rangeStart) ? [{ x: c.x, y, day, causeDay: c.causeDay }] : [];
  });
}

const signedR = (r) => `${r > 0 ? "+" : r < 0 ? "−" : "±"}${Math.abs(r).toFixed(2)}`;

// Chips that pick one of `options`; each label can carry a suffix (the
// cause chips show their r against the selected outcome).
function renderChoice(id, options, selected, suffix, onPick) {
  document.getElementById(id).replaceChildren(...options.map((o) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `chart-mode-btn${o.key === selected ? " active" : ""}`;
    button.textContent = `${o.label}${suffix(o)}`;
    button.addEventListener("click", () => onPick(o.key));
    return button;
  }));
}

// `source` is { metrics, periods } covering the range and the days before it.
export function renderNextDay(source, state) {
  const pick = state.nextDay;
  const cause = NEXT_DAY_CAUSES.find((c) => c.key === pick.cause) ?? NEXT_DAY_CAUSES[0];
  const outcome = NEXT_DAY_OUTCOMES.find((o) => o.key === pick.outcome) ?? NEXT_DAY_OUTCOMES[0];
  const rerender = (change) => {
    Object.assign(state.nextDay, change);
    renderNextDay(source, state);
  };

  const fits = new Map(NEXT_DAY_CAUSES.map((c) =>
    [c.key, linearFit(nextDayPoints(source, c, outcome, state.rangeStart))]));
  renderChoice("next-day-cause", NEXT_DAY_CAUSES, cause.key, (c) => {
    const fit = fits.get(c.key);
    return fit ? ` ${signedR(fit.r)}` : "";
  }, (key) => rerender({ cause: key }));
  renderChoice("next-day-outcome", NEXT_DAY_OUTCOMES, outcome.key, () => "",
               (key) => rerender({ outcome: key }));

  const points = nextDayPoints(source, cause, outcome, state.rangeStart);
  const fit = fits.get(cause.key);
  const xs = points.map((p) => p.x);
  document.getElementById("next-day-note").textContent = fitNote(points, fit);

  makeChart("chart-next-day", state.charts, {
    type: "scatter",
    data: {
      datasets: [
        {
          type: "scatter",
          label: `${outcome.label} next morning`,
          data: points,
          backgroundColor: outcome.color + "cc",
          borderColor: outcome.color,
          pointRadius: 4,
        },
        ...(fit == null ? [] : [trendDataset(fit, xs)]),
      ],
    },
    options: {
      responsive: true,
      scales: {
        x: cause.clock
          ? { ...clockScale(xs), title: { display: true, text: cause.axis } }
          : { type: "linear", grid: { color: "#2a2d3a" }, title: { display: true, text: cause.axis } },
        y: { grid: { color: "#2a2d3a" }, title: { display: true, text: `${outcome.axis} (next morning)` } },
      },
      plugins: {
        legend: { position: "top" },
        tooltip: {
          filter: (item) => item.raw?.day != null,
          callbacks: {
            title: (items) => {
              const p = items[0]?.raw;
              return p ? `${dayWithWeekday(p.causeDay)} → ${WEEKDAYS[new Date(`${p.day}T00:00:00Z`).getUTCDay()]} morning` : "";
            },
            label: (ctx) => `${cause.label} ${cause.format(ctx.raw.x)} · ${outcome.label} ${outcome.format(ctx.raw.y)}`,
          },
        },
      },
    },
  });
}
