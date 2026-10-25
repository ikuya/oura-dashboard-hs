import { scoreClass, scoreLabel, formatDuration } from "../helpers.js";
import { BASELINE_DAYS, baselineMean } from "./baseline.js";
import { READINESS_CONTRIBUTORS, SLEEP_CONTRIBUTORS, lowestContributors } from "./scores.js";
import { stressMinutes } from "./stress.js";

// --- Today's cards ---

const neutralFormat = (v) => (v == null ? "—" : Math.round(v));

// The latest record's value, and how far it sits from the mean of the
// BASELINE_DAYS before it. `better` colours the difference: "higher", "lower",
// or null where neither direction is good (temperature deviation).
function updateCard(prefix, records, {
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
    : baselineMean(history, value, last.day);
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

function updateDragNote(prefix, records, contributors) {
  const el = document.getElementById(`card-${prefix}-drag`);
  if (!el) return;
  const lowest = lowestContributors(records?.[records.length - 1], contributors);
  el.textContent = lowest.length
    ? `Low: ${lowest.map((c) => `${c.short} ${c.value}`).join(", ")}`
    : "";
}

// `vitals` and `vitalsHistory` are nightlyVitalsRows() of the range and of the
// longer history.
export function renderCards(data, history, vitals, vitalsHistory) {
  const { sleep = [], readiness = [], activity = [], stress = [],
          spo2 = [], temperature = [] } = data;
  const past = (metric) => history[metric] ?? [];
  const tempDev = (r) => r.temperature_deviation ?? r.score;

  updateCard("sleep", sleep, { history: past("sleep") });
  updateCard("readiness", readiness, { history: past("readiness") });
  updateDragNote("sleep", sleep, SLEEP_CONTRIBUTORS);
  updateDragNote("readiness", readiness, READINESS_CONTRIBUTORS);
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
  updateCard("hrv", vitals, {
    history: vitalsHistory,
    value: (r) => r.hrv,
    format: (v) => v == null ? "—" : `${Math.round(v)}ms`,
    colored: false,
  });
}
