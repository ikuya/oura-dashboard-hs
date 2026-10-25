import { mainPeriod } from "../helpers.js";
import { makeChart, TIME_SCALE, TIME_SCALE_MINUTE, SERIES_BLUE, SERIES_ORANGE, groupByDay } from "./common.js";
import { averageDataset, averageLegend } from "./baseline.js";

// --- Nightly vitals ---

const HRV_COLOR = SERIES_BLUE;
const HR_COLOR = SERIES_ORANGE;

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

// --- Other vitals ---

export function renderSpo2(spo2, state) {
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
}

export function renderTemperature(temperature, state) {
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
}

export function renderHeartRate(hrData, state) {
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
}

export function renderResilience(resilience, state) {
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
}

export function renderCardioAge(cardiovascular_age, state) {
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
