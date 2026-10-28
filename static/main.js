import { apiFetch } from "./api.js";
import { localDateStr, todayStr, daysAgoStr, setStatus, mainPeriod, syncFreshness, formatAge } from "./helpers.js";
import { renderAll } from "./charts.js";
import { renderHypnogram } from "./charts/sleep.js";
import { renderMonthly } from "./charts/longterm.js";
import { addDaysStr } from "./charts/common.js";
import { BASELINE_DAYS, AVERAGE_DAYS } from "./charts/baseline.js";
import { dailyCsvRows, downloadCsv } from "./export.js";

// Shared across advice IIFEs
let sharedAdviceRaw = "";
let refreshAdviceCalendar = null;

// Set by the sleep stage IIFE below; loadData() calls it after each fetch.
let renderSleepStages = () => {};

// --- State ---
const state = {
  days: 30,
  customRange: null,  // { start, end } picked by hand; null means the `days` preset
  charts: {},
  hrMode: "7d",
  rangeStart: null,   // first day of the selected range
  rangeEnd: null,     // last day of the selected range (today when loaded)
  rangeData: null,    // the loaded range's daily metrics, keyed by metric
  sleepPeriods: [],   // the loaded range, ascending by bedtime_start
  history: null,      // { metrics, sleepPeriods } reaching back past the range for the baselines
  events: null,       // /api/events over the same span as `history`: { tags, workouts, sessions }
  sleepDay: null,     // selected night; null means "the latest one loaded"
  sleepPeriodId: null, // selected period within that night; null means the main sleep
  nextDay: { cause: "steps", outcome: "readiness" }, // Next-Day Effects selection
  monthly: null,      // /api/monthly, fetched once and again after a sync
  monthlyView: "scores",
  hrDate: (() => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`; })(),
};

// --- Sync freshness ---
function renderSyncFreshness(status) {
  const el = document.getElementById("sync-freshness");
  const { level, hours, lagging } = syncFreshness(status);
  el.className = `sync-freshness ${level}`;
  if (hours == null) {
    el.textContent = "Never synced — press Sync";
    return;
  }
  if (level === "fresh") {
    el.textContent = `Last sync ${formatAge(hours)} ago`;
    return;
  }
  // When only some metrics are behind, the others did sync recently, so name
  // the lagging ones rather than call it the last sync.
  const partial = lagging.length < Object.values(status).filter((v) => v.last_synced_at).length;
  el.textContent = partial
    ? `⚠ ${lagging.join(", ")} not synced for ${formatAge(hours)} — press Sync`
    : `⚠ Last sync ${formatAge(hours)} ago — press Sync`;
}

// --- Sync status table ---
async function loadSyncStatus() {
  try {
    const res = await apiFetch("/api/sync/status");
    const status = await res.json();
    renderSyncFreshness(status);
    const table = document.getElementById("sync-status-table");
    table.innerHTML = Object.entries(status)
      .map(([m, v]) => {
        const timeStr = v.last_synced_at
          ? new Date(v.last_synced_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false })
          : "";
        const dayStr = v.last_day ? `${v.last_day} ${timeStr}`.trim() : "never";
        return `<tr><td>${m}</td><td>${dayStr}</td><td>${v.rows} rows</td></tr>`;
      }).join("");
  } catch (_) {}
}

// --- Main load ---
async function loadData() {
  const { start, end } = state.customRange ?? { start: daysAgoStr(state.days), end: todayStr() };
  // The baselines need history before the range: the card compares the last
  // day with the BASELINE_DAYS before it, and the moving average at the
  // range's first day reaches AVERAGE_DAYS back.
  const historyStart = [addDaysStr(start, -AVERAGE_DAYS), addDaysStr(end, -(BASELINE_DAYS + 1))].sort()[0];
  const hrStart = state.hrMode === "1d" ? state.hrDate : daysAgoStr(7);
  const hrEnd = state.hrMode === "1d" ? state.hrDate : end;

  setStatus("Loading...");

  try {
    const [metricsRes, hrRes, sleepRes, eventsRes] = await Promise.all([
      apiFetch(`/api/metrics?start=${historyStart}&end=${end}`),
      apiFetch(`/api/heartrate?start=${hrStart}&end=${hrEnd}`),
      apiFetch(`/api/sleep_periods?start=${historyStart}&end=${end}`),
      apiFetch(`/api/events?start=${historyStart}&end=${end}`),
    ]);

    if (!metricsRes.ok) throw new Error(`Metrics fetch failed: ${metricsRes.status}`);
    const metricsHistory = await metricsRes.json();
    const hrData = hrRes.ok ? await hrRes.json() : [];
    const sleepHistory = sleepRes.ok ? await sleepRes.json() : [];
    const events = eventsRes.ok ? await eventsRes.json() : {};
    const inRange = (r) => r.day >= start;
    const data = Object.fromEntries(
      Object.entries(metricsHistory).map(([m, rows]) => [m, rows.filter(inRange)]));
    state.rangeStart = start;
    state.rangeEnd = end;
    state.rangeData = data;
    state.history = { metrics: metricsHistory, sleepPeriods: sleepHistory };
    state.sleepPeriods = sleepHistory.filter(inRange);
    state.events = events;

    renderAll(data, hrData, state);
    renderSleepStages();
    await loadMonthly();
    setStatus("");
    await loadSyncStatus();
  } catch (e) {
    setStatus(`Error: ${e.message}`, true);
  }
}

// The whole history does not change with the range, so it is fetched once.
async function loadMonthly() {
  if (!state.monthly) {
    const res = await apiFetch("/api/monthly");
    if (!res.ok) throw new Error(`Monthly fetch failed: ${res.status}`);
    state.monthly = await res.json();
  }
  renderMonthly(state.monthly, state);
}

// --- Sync button ---
document.getElementById("sync-btn").addEventListener("click", async () => {
  const btn = document.getElementById("sync-btn");
  btn.disabled = true;
  btn.textContent = "Syncing...";
  setStatus("Syncing with Oura API...");

  try {
    const res = await apiFetch("/api/sync", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) });
    const result = await res.json();

    if (!res.ok) {
      setStatus(`Sync failed (${res.status}): ${result.error || res.statusText}`, true);
      return;
    }

    const synced = result.synced || {};
    const total = Object.values(synced).reduce((a, b) => a + b, 0);
    const errors = result.errors || {};
    const errMetrics = Object.keys(errors);

    let msg = total > 0 ? `Sync complete: ${total} new records fetched.` : "Sync complete: already up to date.";

    if (errMetrics.length > 0) {
      const errDetails = errMetrics.map(m => `${m}: ${errors[m].split("\n")[0]}`).join("; ");
      msg += ` | Failed — ${errDetails}`;
      setStatus(msg, true);
    } else {
      setStatus(msg);
    }
    state.monthly = null;
    await loadData();
  } catch (e) {
    setStatus(`Sync error: ${e.message}`, true);
  } finally {
    btn.disabled = false;
    btn.textContent = "Sync";
  }
});

// --- CSV export ---
document.getElementById("csv-btn").addEventListener("click", () => {
  if (!state.rangeData) return;
  const rows = dailyCsvRows(state.rangeData, state.sleepPeriods, state.events ?? {});
  downloadCsv(`oura-${state.rangeStart}_${state.rangeEnd}.csv`, rows);
});

// --- Range buttons ---
const customForm = document.getElementById("custom-range");
const customBtn = document.getElementById("range-custom-btn");

function markRangeButton(active) {
  document.querySelectorAll(".range-btns button").forEach((b) => b.classList.toggle("active", b === active));
}

document.querySelectorAll(".range-btns button[data-days]").forEach((btn) => {
  btn.addEventListener("click", () => {
    markRangeButton(btn);
    customForm.classList.add("hidden");
    state.customRange = null;
    state.days = parseInt(btn.dataset.days, 10);
    loadData();
  });
});

// A range picked by hand. The charts load every sleep period in it with its
// 5-minute series, so it is capped at a year; the Monthly Averages chart
// covers longer spans.
const MAX_CUSTOM_DAYS = 366;

customBtn.addEventListener("click", () => {
  const opening = customForm.classList.contains("hidden");
  customForm.classList.toggle("hidden", !opening);
  if (opening) {
    customForm.elements.start.value = state.rangeStart ?? daysAgoStr(state.days);
    customForm.elements.end.value = state.rangeEnd ?? todayStr();
    customForm.elements.end.max = todayStr();
  }
});

customForm.addEventListener("submit", (e) => {
  e.preventDefault();
  const start = customForm.elements.start.value;
  const end = customForm.elements.end.value;
  if (!start || !end || start > end) {
    setStatus("Custom range: the start has to be on or before the end.", true);
    return;
  }
  const days = Math.round((new Date(`${end}T00:00:00Z`) - new Date(`${start}T00:00:00Z`)) / 86400000) + 1;
  if (days > MAX_CUSTOM_DAYS) {
    setStatus(`Custom range: at most ${MAX_CUSTOM_DAYS} days (this is ${days}).`, true);
    return;
  }
  markRangeButton(customBtn);
  customForm.classList.add("hidden");
  state.customRange = { start, end };
  loadData();
});

// --- HR mode buttons ---
function updateHrDayLabel() {
  const d = new Date(state.hrDate + "T00:00:00");
  const label = d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
  document.getElementById("hr-day-label").textContent = label;
  document.getElementById("hr-next-day").disabled = (state.hrDate >= todayStr());
}

document.getElementById("hr-btn-7d").addEventListener("click", () => {
  state.hrMode = "7d";
  document.getElementById("hr-btn-7d").classList.add("active");
  document.getElementById("hr-btn-1d").classList.remove("active");
  document.getElementById("hr-range-note").classList.remove("hidden");
  document.getElementById("hr-day-nav").classList.add("hidden");
  loadData();
});

document.getElementById("hr-btn-1d").addEventListener("click", () => {
  state.hrMode = "1d";
  document.getElementById("hr-btn-7d").classList.remove("active");
  document.getElementById("hr-btn-1d").classList.add("active");
  document.getElementById("hr-range-note").classList.add("hidden");
  document.getElementById("hr-day-nav").classList.remove("hidden");
  updateHrDayLabel();
  loadData();
});

document.getElementById("hr-prev-day").addEventListener("click", () => {
  const d = new Date(state.hrDate + "T00:00:00");
  d.setDate(d.getDate() - 1);
  state.hrDate = localDateStr(d);
  updateHrDayLabel();
  loadData();
});

document.getElementById("hr-next-day").addEventListener("click", () => {
  const d = new Date(state.hrDate + "T00:00:00");
  d.setDate(d.getDate() + 1);
  state.hrDate = localDateStr(d);
  updateHrDayLabel();
  loadData();
});


// --- Sleep stages ---
// The whole range arrives in one fetch, so moving between nights is a re-render
// rather than a request. That ties how far back the arrows reach to the range
// buttons (7d/14d/...), which is why they disable at the ends.
(function () {
  const nav       = document.getElementById("sleep-day-nav");
  const dayLabel  = document.getElementById("sleep-day-label");
  const prevBtn   = document.getElementById("sleep-prev-day");
  const nextBtn   = document.getElementById("sleep-next-day");
  const tabs      = document.getElementById("sleep-period-tabs");
  const rangeLabel = document.getElementById("sleep-period-range");
  const note      = document.getElementById("sleep-stage-note");

  function loadedDays() {
    return [...new Set(state.sleepPeriods.map((p) => p.day))].sort();
  }

  function periodsForDay(day) {
    return state.sleepPeriods.filter((p) => p.day === day);
  }

  function startTimeLabel(period) {
    const d = new Date(period.bedtime_start);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  }

  // The chart's own tooltip only shows a point's time on hover, so the first
  // and last timestamps of the selected period are duplicated here as text
  // that stays visible.
  function fullClockLabel(d) {
    return `${String(d.getMonth() + 1).padStart(2, "0")}/${String(d.getDate()).padStart(2, "0")} `
      + `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  }

  function periodRangeLabel(period) {
    const start = fullClockLabel(new Date(period.bedtime_start));
    const end = fullClockLabel(new Date(period.bedtime_end));
    return `${start} → ${end}`;
  }

  function renderTabs(periods, selected) {
    // A single period needs no chooser.
    if (periods.length < 2) {
      tabs.innerHTML = "";
      return;
    }
    const main = mainPeriod(periods);
    tabs.innerHTML = periods
      .map((p) => {
        const label = p === main ? "Main" : startTimeLabel(p);
        const cls = p.id === selected.id ? "chart-mode-btn active" : "chart-mode-btn";
        return `<button class="${cls}" data-period-id="${p.id}">${label}</button>`;
      })
      .join("");
  }

  function render() {
    const days = loadedDays();

    if (days.length === 0) {
      nav.classList.add("hidden");
      tabs.innerHTML = "";
      rangeLabel.textContent = "";
      note.textContent = "No sleep period data in this range — press Sync.";
      renderHypnogram(null, state);
      return;
    }

    nav.classList.remove("hidden");
    note.textContent = "";

    // A range change can drop the selected night out of the loaded data.
    if (!days.includes(state.sleepDay)) {
      state.sleepDay = days[days.length - 1];
      state.sleepPeriodId = null;
    }

    const periods = periodsForDay(state.sleepDay);
    const period =
      periods.find((p) => p.id === state.sleepPeriodId)
      ?? mainPeriod(periods) ?? periods[0];
    state.sleepPeriodId = period.id;

    const index = days.indexOf(state.sleepDay);
    dayLabel.textContent = state.sleepDay;
    prevBtn.disabled = index === 0;
    nextBtn.disabled = index === days.length - 1;

    renderTabs(periods, period);
    rangeLabel.textContent = periodRangeLabel(period);
    renderHypnogram(period, state);
  }

  function step(delta) {
    const days = loadedDays();
    const next = days[days.indexOf(state.sleepDay) + delta];
    if (next === undefined) return;
    state.sleepDay = next;
    state.sleepPeriodId = null;
    render();
  }

  prevBtn.addEventListener("click", () => step(-1));
  nextBtn.addEventListener("click", () => step(1));

  tabs.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-period-id]");
    if (!btn) return;
    state.sleepPeriodId = btn.dataset.periodId;
    render();
  });

  renderSleepStages = render;
})();

// --- Chart full screen ---
// Each chart card gets a button that opens it over the whole page. Where the
// browser allows it (Android Chrome) the card also goes full screen and turns
// landscape; iOS Safari allows neither, so there the card only covers the page
// and the phone is turned by hand. Chart.js follows the box size by itself.
// A history entry makes the back gesture close the card, not leave the page.
(function () {
  let expanded = null;

  // A reload keeps the entry pushed below, with no card open to close.
  if (history.state?.chartExpanded) history.replaceState(null, "");

  function setButton(card, open) {
    const btn = card.querySelector(".chart-expand-btn");
    btn.textContent = open ? "✕" : "⤢";
    btn.setAttribute("aria-label", open ? "閉じる" : "全画面で表示");
  }

  function open(card) {
    expanded = card;
    card.classList.add("expanded");
    document.body.classList.add("chart-expanded");
    setButton(card, true);
    history.pushState({ chartExpanded: true }, "");
    if (card.requestFullscreen) {
      card.requestFullscreen()
        .then(() => screen.orientation?.lock?.("landscape"))
        .catch(() => {});
    }
  }

  // Runs on popstate; everything else that closes the card goes through
  // history.back() so the pushed entry is popped too.
  function close() {
    if (!expanded) return;
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    // Leaving full screen should release the landscape lock; make sure of it.
    try { screen.orientation?.unlock?.(); } catch {}
    expanded.classList.remove("expanded");
    document.body.classList.remove("chart-expanded");
    setButton(expanded, false);
    expanded = null;
  }

  for (const card of document.querySelectorAll(".chart-card")) {
    if (!card.querySelector(".chart-box")) continue;
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "chart-expand-btn";
    btn.addEventListener("click", () => (expanded === card ? history.back() : open(card)));
    const hint = document.createElement("p");
    hint.className = "chart-expand-hint";
    hint.textContent = "横向きにすると広く表示できます";
    card.append(btn, hint);
    setButton(card, false);
  }

  window.addEventListener("popstate", close);
  // Leaving full screen (Esc, Android's back gesture) closes the card as well.
  document.addEventListener("fullscreenchange", () => {
    if (!document.fullscreenElement && expanded && history.state?.chartExpanded) history.back();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && expanded && !document.fullscreenElement) history.back();
  });
})();

// --- Advice comparison ---
const COMPARISON_LABELS = { readiness: "Readiness", sleep: "Sleep", activity: "Activity" };

// Each headline score's mean over the advice's period, with how far it moved
// from the previous advice's period: "Readiness 78 +2.4 ↑".
function renderAdviceComparison(el, comparison) {
  el.replaceChildren();
  const scores = (comparison?.scores ?? []).filter((s) => s.average != null);
  if (scores.length === 0) return;
  const prev = comparison.previous;
  const label = document.createElement("span");
  label.className = "comparison-label";
  label.textContent = prev
    ? `期間平均スコア（前回 ${prev.saved_at.slice(0, 10)} 保存分との差）`
    : "期間平均スコア（前回のアドバイスなし）";
  el.append(label);
  for (const s of scores) {
    const item = document.createElement("span");
    const value = document.createElement("span");
    value.className = "comparison-value";
    value.textContent = Math.round(s.average);
    item.append(`${COMPARISON_LABELS[s.metric] ?? s.metric} `, value);
    if (s.previous != null) {
      const d = s.average - s.previous;
      const shown = Math.abs(d).toFixed(1);
      const zero = Number.parseFloat(shown) === 0;
      const delta = document.createElement("span");
      delta.textContent = zero ? " ±0" : ` ${d > 0 ? "+" : "−"}${shown} ${d > 0 ? "↑" : "↓"}`;
      if (!zero) delta.className = d > 0 ? "delta-good" : "delta-bad";
      item.append(delta);
    }
    el.append(item);
  }
}

// --- Advice button ---
(function () {
  const adviceBtn = document.getElementById("advice-btn");
  const overlay = document.getElementById("advice-overlay");
  const closeBtn = document.getElementById("advice-close-btn");
  const copyBtn = document.getElementById("advice-copy-btn");
  const contentEl = document.getElementById("advice-content");
  const periodEl = document.getElementById("advice-period");
  const comparisonEl = document.getElementById("advice-comparison");
  const versionsEl = document.getElementById("advice-versions");
  const confirmOverlay = document.getElementById("confirm-overlay");
  const confirmOkBtn = document.getElementById("confirm-ok-btn");
  const confirmCancelBtn = document.getElementById("confirm-cancel-btn");
  function openModal() { overlay.classList.remove("hidden"); }
  function closeModal() { overlay.classList.add("hidden"); }
  function openConfirm() { confirmOverlay.classList.remove("hidden"); }
  function closeConfirm() { confirmOverlay.classList.add("hidden"); }

  overlay.addEventListener("click", (e) => { if (e.target === overlay) closeModal(); });
  confirmOverlay.addEventListener("click", (e) => { if (e.target === confirmOverlay) closeConfirm(); });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      if (!confirmOverlay.classList.contains("hidden")) closeConfirm();
      else if (!overlay.classList.contains("hidden")) closeModal();
    }
  });
  closeBtn.addEventListener("click", closeModal);
  confirmCancelBtn.addEventListener("click", closeConfirm);

  copyBtn.disabled = true;
  copyBtn.addEventListener("click", async () => {
    if (!sharedAdviceRaw) return;
    let success = false;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      try {
        await navigator.clipboard.writeText(sharedAdviceRaw);
        success = true;
      } catch (_) {}
    }
    if (!success) {
      try {
        const ta = document.createElement("textarea");
        ta.value = sharedAdviceRaw;
        ta.readOnly = true;
        ta.style.cssText = "position:fixed;top:0;left:0;opacity:0;pointer-events:none;";
        document.body.appendChild(ta);
        ta.focus({ preventScroll: true });
        ta.select();
        ta.setSelectionRange(0, ta.value.length);
        success = document.execCommand("copy");
        document.body.removeChild(ta);
      } catch (_) {}
    }
    copyBtn.textContent = success ? "コピー済" : "失敗";
    setTimeout(() => { copyBtn.textContent = "コピー"; }, 2000);
  });

  adviceBtn.addEventListener("click", () => openConfirm());

  async function wait(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async function pollAdviceJob(jobId) {
    const maxAttempts = 80;
    for (let i = 0; i < maxAttempts; i++) {
      const res = await apiFetch(`/api/advice/${jobId}`);
      const data = await res.json();

      if (data.status === "completed") {
        return data;
      }
      if (data.status === "failed") {
        throw new Error(data.error || "分析に失敗しました。");
      }
      await wait(1500);
    }
    throw new Error("分析がタイムアウトしました。");
  }

  confirmOkBtn.addEventListener("click", async () => {
    closeConfirm();
    adviceBtn.disabled = true;
    adviceBtn.textContent = "分析中...";
    periodEl.textContent = "";
    versionsEl.replaceChildren();
    comparisonEl.replaceChildren();
    copyBtn.disabled = true;
    copyBtn.textContent = "コピー";
    sharedAdviceRaw = "";
    contentEl.innerHTML = `
      <div class="advice-loading">
        <div class="advice-spinner"></div>
        <span>Claudeが健康データを分析しています...</span>
      </div>`;
    openModal();

    try {
      const res = await apiFetch("/api/advice", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({}),
      });
      const queued = await res.json();

      if (!res.ok) {
        contentEl.innerHTML = `<p style="color:var(--red)">エラー: ${queued.error || res.status}</p>`;
        return;
      }

      const data = await pollAdviceJob(queued.job_id);

      if (data.period) {
        periodEl.textContent = `分析期間: ${data.period.start} 〜 ${data.period.end}`;
      }
      renderAdviceComparison(comparisonEl, data.comparison);
      sharedAdviceRaw = data.advice || "";
      contentEl.innerHTML = marked.parse(sharedAdviceRaw);
      copyBtn.disabled = false;
      if (typeof refreshAdviceCalendar === "function") refreshAdviceCalendar();
    } catch (e) {
      contentEl.innerHTML = `<p style="color:var(--red)">ネットワークエラー: ${e.message}</p>`;
    } finally {
      adviceBtn.disabled = false;
      adviceBtn.textContent = "Advice";
    }
  });
})();

// --- Advice History Calendar ---
(function () {
  const calState = { year: 0, month: 0, adviceDates: new Set() };

  const prevBtn    = document.getElementById("cal-prev-btn");
  const nextBtn    = document.getElementById("cal-next-btn");
  const monthLabel = document.getElementById("cal-month-label");
  const grid       = document.getElementById("calendar-grid");
  const overlay    = document.getElementById("advice-overlay");
  const contentEl  = document.getElementById("advice-content");
  const periodEl   = document.getElementById("advice-period");
  const comparisonEl = document.getElementById("advice-comparison");
  const versionsEl = document.getElementById("advice-versions");
  const copyBtn    = document.getElementById("advice-copy-btn");

  function openModal() { overlay.classList.remove("hidden"); }

  async function loadAdviceDates() {
    try {
      const res = await apiFetch("/api/advice/history");
      if (!res.ok) return;
      const list = await res.json();
      calState.adviceDates = new Set(list.map(e => e.day));
      renderCalendar();
    } catch (_) {}
  }

  function renderCalendar() {
    const MONTHS = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"];
    const DAYS   = ["M","T","W","T","F","S","S"];

    monthLabel.textContent = `${calState.year}年 ${MONTHS[calState.month]}`;

    const today        = new Date().toISOString().slice(0, 10);
    const rawDow       = new Date(calState.year, calState.month, 1).getDay();
    const firstDow     = (rawDow + 6) % 7;
    const daysInMonth  = new Date(calState.year, calState.month + 1, 0).getDate();
    const prevMonthEnd = new Date(calState.year, calState.month, 0).getDate();

    let html = DAYS.map(d => `<div class="cal-day-name">${d}</div>`).join("");

    for (let i = firstDow - 1; i >= 0; i--) {
      html += `<div class="cal-day other-month">${prevMonthEnd - i}</div>`;
    }

    for (let d = 1; d <= daysInMonth; d++) {
      const iso = `${calState.year}-${String(calState.month + 1).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
      const isToday   = iso === today;
      const hasAdvice = calState.adviceDates.has(iso);
      let cls = "cal-day";
      if (isToday)   cls += " today";
      if (hasAdvice) cls += " has-advice";
      html += `<div class="${cls}"${hasAdvice ? ` data-date="${iso}"` : ""}>${d}</div>`;
    }

    const remainder = (firstDow + daysInMonth) % 7;
    if (remainder !== 0) {
      for (let d = 1; d <= 7 - remainder; d++) {
        html += `<div class="cal-day other-month">${d}</div>`;
      }
    }

    grid.innerHTML = html;
  }

  // A saved_at like 2024-01-14T05:05:00.123456+00:00 in local time: "14:05",
  // or "2024/01/14 14:05" with the date. Date can't parse microseconds.
  function savedStamp(savedAt, withDate) {
    const d = new Date(savedAt.replace(/(\.\d{3})\d+/, "$1"));
    if (isNaN(d)) return savedAt;
    const opts = { hour: "2-digit", minute: "2-digit" };
    if (withDate) Object.assign(opts, { year: "numeric", month: "2-digit", day: "2-digit" });
    return d.toLocaleString("ja-JP", opts);
  }

  // A button per advice saved that day, so an earlier one is not hidden by a
  // later run; nothing when there is only one.
  function renderVersions(isoDate, savedAts, current) {
    versionsEl.replaceChildren();
    if (!savedAts || savedAts.length < 2) return;
    for (const at of savedAts) {
      const btn = document.createElement("button");
      btn.className = "advice-version-btn" + (at === current ? " active" : "");
      btn.textContent = savedStamp(at, false);
      btn.addEventListener("click", () => { if (at !== current) openSavedAdvice(isoDate, at); });
      versionsEl.appendChild(btn);
    }
  }

  async function openSavedAdvice(isoDate, savedAt) {
    sharedAdviceRaw = "";
    copyBtn.disabled = true;
    copyBtn.textContent = "コピー";
    periodEl.textContent = "";
    if (!savedAt) versionsEl.replaceChildren();
    comparisonEl.replaceChildren();
    contentEl.innerHTML = `
      <div class="advice-loading">
        <div class="advice-spinner"></div>
        <span>アドバイスを読み込んでいます...</span>
      </div>`;
    openModal();

    try {
      const query = savedAt ? `?at=${encodeURIComponent(savedAt)}` : "";
      const res  = await apiFetch(`/api/advice/history/${isoDate}${query}`);
      const data = await res.json();
      if (!res.ok) {
        contentEl.innerHTML = `<p style="color:var(--red)">エラー: ${data.error || res.status}</p>`;
        return;
      }
      if (data.period) {
        periodEl.textContent = `分析期間: ${data.period.start} 〜 ${data.period.end}　（保存: ${savedStamp(data.saved_at, true)}）`;
      }
      renderVersions(isoDate, data.saved_ats, data.saved_at);
      renderAdviceComparison(comparisonEl, data.comparison);
      sharedAdviceRaw = data.advice || "";
      contentEl.innerHTML = marked.parse(sharedAdviceRaw);
      copyBtn.disabled = false;
    } catch (e) {
      contentEl.innerHTML = `<p style="color:var(--red)">ネットワークエラー: ${e.message}</p>`;
    }
  }

  grid.addEventListener("click", (e) => {
    const cell = e.target.closest(".has-advice");
    if (cell) openSavedAdvice(cell.dataset.date);
  });

  prevBtn.addEventListener("click", () => {
    if (calState.month === 0) { calState.year--; calState.month = 11; }
    else calState.month--;
    renderCalendar();
  });

  nextBtn.addEventListener("click", () => {
    if (calState.month === 11) { calState.year++; calState.month = 0; }
    else calState.month++;
    renderCalendar();
  });

  const now = new Date();
  calState.year  = now.getFullYear();
  calState.month = now.getMonth();
  loadAdviceDates();
  refreshAdviceCalendar = loadAdviceDates;
})();

// --- Logout button ---
document.getElementById("logout-btn").addEventListener("click", async () => {
  await apiFetch("/logout", { method: "POST" });
  location.href = "/login";
});

// --- Init ---
loadData();
// A tab left open would otherwise keep showing the age it had at load time.
setInterval(loadSyncStatus, 10 * 60 * 1000);
