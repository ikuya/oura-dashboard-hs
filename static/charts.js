// The dashboard's charts, one module per section under charts/: common.js
// (Chart.js defaults and shared parts), baseline.js (the trailing averages),
// cards.js, scores.js, sleep.js, vitals.js, correlation.js, stress.js and
// activity.js. This module only draws them all for the selected range.
import { SERIES_BLUE, SERIES_ORANGE, SERIES_AQUA } from "./charts/common.js";
import { renderCards } from "./charts/cards.js";
import { renderScores, renderSleepQuality, renderContributorHeatmap,
         READINESS_CONTRIBUTORS, SLEEP_CONTRIBUTORS } from "./charts/scores.js";
import { renderStageDurations, renderBedtimeWake } from "./charts/sleep.js";
import { nightlyVitalsRows, renderNightlyVitals, renderSpo2, renderTemperature,
         renderHeartRate, renderResilience, renderCardioAge } from "./charts/vitals.js";
import { renderBedtimeScore, renderWeekdayAverages, renderNextDay } from "./charts/correlation.js";
import { renderStressRecovery } from "./charts/stress.js";
import { renderActivityBreakdown, renderSteps } from "./charts/activity.js";

// `data` and `state.sleepPeriods` cover the selected range; `state.history`
// holds the same series reaching back far enough for the baselines.
export function renderAll(data, hrData, state) {
  const { sleep = [], readiness = [], activity = [], stress = [],
          spo2 = [], temperature = [], resilience = [],
          cardiovascular_age = [] } = data;
  const history = state.history?.metrics ?? data;
  const past = (metric) => history[metric] ?? [];
  const periods = state.sleepPeriods ?? [];
  const vitalsHistory = nightlyVitalsRows(state.history?.sleepPeriods ?? periods);

  renderCards(data, history, nightlyVitalsRows(periods), vitalsHistory);

  renderScores(readiness, sleep, activity, history, state);
  renderContributorHeatmap("heatmap-readiness", readiness, READINESS_CONTRIBUTORS, state);
  renderContributorHeatmap("heatmap-sleep", sleep, SLEEP_CONTRIBUTORS, state);
  renderSleepQuality(sleep, readiness, state);

  renderStageDurations(periods, state);
  renderBedtimeWake(periods, state);
  renderNightlyVitals(periods, vitalsHistory, state);
  renderBedtimeScore(periods, sleep, state);
  renderWeekdayAverages([
    { label: "Readiness", records: readiness, color: SERIES_AQUA },
    { label: "Sleep", records: sleep, color: SERIES_BLUE },
    { label: "Activity", records: activity, color: SERIES_ORANGE },
  ], state);
  renderNextDay({ metrics: history, periods: state.history?.sleepPeriods ?? periods }, state);

  renderStressRecovery(stress, past("stress"), state);
  renderActivityBreakdown(activity, past("activity"), state);
  renderSteps(activity, past("activity"), state);

  renderSpo2(spo2, state);
  renderTemperature(temperature, state);
  renderHeartRate(hrData, state);
  renderResilience(resilience, state);
  renderCardioAge(cardiovascular_age, state);
}
