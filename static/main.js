import { apiFetch } from "./api.js";
import { localDateStr, todayStr, daysAgoStr, setStatus } from "./helpers.js";
import { renderAll } from "./charts.js";

// Shared across advice IIFEs
let sharedAdviceRaw = "";
let refreshAdviceCalendar = null;

// --- State ---
const state = {
  days: 14,
  charts: {},
  hrMode: "7d",
  hrDate: (() => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`; })(),
};

// --- Sync status table ---
async function loadSyncStatus() {
  try {
    const res = await apiFetch("/api/sync/status");
    const status = await res.json();
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
  const end = todayStr();
  const start = daysAgoStr(state.days);
  const hrStart = state.hrMode === "1d" ? state.hrDate : daysAgoStr(7);
  const hrEnd = state.hrMode === "1d" ? state.hrDate : end;

  setStatus("Loading...");

  try {
    const [metricsRes, hrRes] = await Promise.all([
      apiFetch(`/api/metrics?start=${start}&end=${end}`),
      apiFetch(`/api/heartrate?start=${hrStart}&end=${hrEnd}`),
    ]);

    if (!metricsRes.ok) throw new Error(`Metrics fetch failed: ${metricsRes.status}`);
    const data = await metricsRes.json();
    const hrData = hrRes.ok ? await hrRes.json() : [];

    renderAll(data, hrData, state);
    setStatus("");
    await loadSyncStatus();
  } catch (e) {
    setStatus(`Error: ${e.message}`, true);
  }
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
    await loadData();
  } catch (e) {
    setStatus(`Sync error: ${e.message}`, true);
  } finally {
    btn.disabled = false;
    btn.textContent = "Sync";
  }
});

// --- Range buttons ---
document.querySelectorAll(".range-btns button").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".range-btns button").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    state.days = parseInt(btn.dataset.days, 10);
    loadData();
  });
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

// --- Advice button ---
(function () {
  const adviceBtn = document.getElementById("advice-btn");
  const overlay = document.getElementById("advice-overlay");
  const closeBtn = document.getElementById("advice-close-btn");
  const copyBtn = document.getElementById("advice-copy-btn");
  const contentEl = document.getElementById("advice-content");
  const periodEl = document.getElementById("advice-period");
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

  async function openSavedAdvice(isoDate) {
    sharedAdviceRaw = "";
    copyBtn.disabled = true;
    copyBtn.textContent = "コピー";
    periodEl.textContent = "";
    contentEl.innerHTML = `
      <div class="advice-loading">
        <div class="advice-spinner"></div>
        <span>アドバイスを読み込んでいます...</span>
      </div>`;
    openModal();

    try {
      const res  = await apiFetch(`/api/advice/history/${isoDate}`);
      const data = await res.json();
      if (!res.ok) {
        contentEl.innerHTML = `<p style="color:var(--red)">エラー: ${data.error || res.status}</p>`;
        return;
      }
      if (data.period) {
        periodEl.textContent = `分析期間: ${data.period.start} 〜 ${data.period.end}　（保存日: ${isoDate}）`;
      }
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

// --- Login modal ---
(function () {
  const overlay   = document.getElementById("login-overlay");
  const input     = document.getElementById("login-password-input");
  const submitBtn = document.getElementById("login-submit-btn");
  const errorEl   = document.getElementById("login-error");

  function showLoginModal() {
    errorEl.textContent = "";
    overlay.classList.remove("hidden");
    setTimeout(() => input.focus(), 50);
  }

  function hideLoginModal() {
    overlay.classList.add("hidden");
    input.value = "";
    errorEl.textContent = "";
  }

  window.showLoginModal = showLoginModal;

  async function doLogin() {
    const password = input.value;
    if (!password) return;
    submitBtn.disabled = true;
    submitBtn.textContent = "...";
    errorEl.textContent = "";
    try {
      const res = await fetch("/api/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ password }),
      });
      if (res.ok) {
        hideLoginModal();
        loadData();
        if (typeof refreshAdviceCalendar === "function") refreshAdviceCalendar();
      } else {
        const data = await res.json();
        errorEl.textContent = data.error || "パスワードが違います";
        input.value = "";
        input.focus();
      }
    } catch (e) {
      errorEl.textContent = "ネットワークエラー";
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = "ログイン";
    }
  }

  submitBtn.addEventListener("click", doLogin);
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") doLogin(); });
})();

// --- Logout button ---
document.getElementById("logout-btn").addEventListener("click", async () => {
  await fetch("/api/logout", { method: "POST" });
  window.showLoginModal();
});

// --- Init ---
loadData();
