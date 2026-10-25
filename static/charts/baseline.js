import { addDaysStr, valuesByDay } from "./common.js";

// --- Personal baselines ---

// Today's card is compared with the mean of the BASELINE_DAYS before it, and
// the daily charts carry an AVERAGE_DAYS trailing mean. Both reach back past
// the selected range, so loadData() fetches that much more history.
export const BASELINE_DAYS = 28;
export const AVERAGE_DAYS = 7;

// A window this sparse (a ring left off for a week) says little about "usual".
const MIN_BASELINE_VALUES = 7;
const MIN_AVERAGE_VALUES = 4;

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

// The mean of the BASELINE_DAYS before `day`, or null when too few of them
// have a value.
export function baselineMean(history, value, day) {
  return windowMean(valuesByDay(history, value), addDaysStr(day, -1), BASELINE_DAYS, MIN_BASELINE_VALUES);
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
export function averageLegend(base = {}) {
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
