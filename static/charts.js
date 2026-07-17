import { scoreColor, scoreClass } from "./helpers.js";

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

export function makeChart(id, charts, config) {
  if (charts[id]) {
    charts[id].destroy();
  }
  const ctx = document.getElementById(id).getContext("2d");
  charts[id] = new Chart(ctx, config);
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
