// Translations for the advice UI (confirm dialog, report modal, history
// calendar) and the language the reports are generated in. The rest of the
// dashboard is English only.
//
// The language is the viewer's pick from the header toggle, kept in
// localStorage; before any pick it follows the browser. The server falls back
// to its advice-language setting only when a request names no language.

const STORAGE_KEY = "adviceLang";
export const LANGS = ["ja", "en"];

const MESSAGES = {
  ja: {
    "lang.button": "JA",
    "lang.title": "アドバイスの言語: 日本語（クリックで English）",
    "confirm.message": "Claudeに健康データを送信して分析しますか？",
    "confirm.cancel": "キャンセル",
    "confirm.ok": "分析する",
    "modal.title": "健康アドバイス",
    "modal.close": "閉じる",
    "copy.label": "コピー",
    "copy.title": "Markdownをコピー",
    "copy.done": "コピー済",
    "copy.failed": "失敗",
    "advice.analyzing": "分析中...",
    "loading.analyzing": "Claudeが健康データを分析しています...",
    "loading.history": "アドバイスを読み込んでいます...",
    "period": "分析期間: {start} 〜 {end}",
    "period.saved": "（保存: {at}）",
    "comparison.previous": "期間平均スコア（前回 {date} 保存分との差）",
    "comparison.none": "期間平均スコア（前回のアドバイスなし）",
    "error": "エラー: {message}",
    "error.network": "ネットワークエラー: {message}",
    "error.no_data": "データがありません。まずSyncを実行してください。",
    "error.claude_not_found": "claude コマンドが見つかりません。Claude Code がインストールされているか確認してください。",
    "error.claude_failed": "Claude Code の実行に失敗しました。",
    "error.timeout": "分析がタイムアウトしました。",
    "error.failed": "分析に失敗しました。",
    "calendar.prev": "前の月",
    "calendar.next": "次の月",
  },
  en: {
    "lang.button": "EN",
    "lang.title": "Advice language: English (click for 日本語)",
    "confirm.message": "Send your health data to Claude for analysis?",
    "confirm.cancel": "Cancel",
    "confirm.ok": "Analyze",
    "modal.title": "Health Advice",
    "modal.close": "Close",
    "copy.label": "Copy",
    "copy.title": "Copy as Markdown",
    "copy.done": "Copied",
    "copy.failed": "Failed",
    "advice.analyzing": "Analyzing...",
    "loading.analyzing": "Claude is analyzing your health data...",
    "loading.history": "Loading advice...",
    "period": "Period: {start} – {end}",
    "period.saved": " (saved {at})",
    "comparison.previous": "Average scores over the period (change since the advice saved {date})",
    "comparison.none": "Average scores over the period (no previous advice)",
    "error": "Error: {message}",
    "error.network": "Network error: {message}",
    "error.no_data": "No data yet. Run a sync first.",
    "error.claude_not_found": "The claude command was not found. Check that Claude Code is installed.",
    "error.claude_failed": "Claude Code failed to run.",
    "error.timeout": "The analysis timed out.",
    "error.failed": "The analysis failed.",
    "calendar.prev": "Previous month",
    "calendar.next": "Next month",
  },
};

// Storage can be unavailable (private mode, blocked site data); the language
// then lasts until the page is reloaded.
function stored() {
  try { return localStorage.getItem(STORAGE_KEY); } catch { return null; }
}

function browserLang() {
  return (navigator.language || "").toLowerCase().startsWith("ja") ? "ja" : "en";
}

let current = LANGS.includes(stored()) ? stored() : browserLang();

export function getLang() { return current; }

export function setLang(lang) {
  if (!LANGS.includes(lang) || lang === current) return;
  current = lang;
  try { localStorage.setItem(STORAGE_KEY, lang); } catch {}
  applyStaticTexts();
  window.dispatchEvent(new CustomEvent("langchange", { detail: lang }));
}

// The message for `key` with each {name} replaced from `vars`; the key itself
// when no language has it, so a missing entry shows up instead of vanishing.
export function t(key, vars = {}) {
  const msg = MESSAGES[current][key] ?? MESSAGES.en[key] ?? key;
  return msg.replace(/\{(\w+)\}/g, (m, name) => (name in vars ? String(vars[name]) : m));
}

// The localized message for a failed advice request: by its error_code when
// it has a translation (with what the CLI said, if anything), else the
// server's own text, else a generic one.
export function adviceErrorText(data) {
  const key = data?.error_code && `error.${data.error_code}`;
  if (key && key in MESSAGES[current]) {
    return data.error_detail ? `${t(key)}\n${data.error_detail}` : t(key);
  }
  return data?.error || t("error.failed");
}

// Elements carry data-i18n (text), data-i18n-title and data-i18n-aria-label;
// a data-i18n-lang container gets the lang attribute for its contents.
export function applyStaticTexts(root = document) {
  for (const el of root.querySelectorAll("[data-i18n-lang]")) el.lang = current;
  for (const el of root.querySelectorAll("[data-i18n]")) el.textContent = t(el.dataset.i18n);
  for (const el of root.querySelectorAll("[data-i18n-title]")) el.title = t(el.dataset.i18nTitle);
  for (const el of root.querySelectorAll("[data-i18n-aria-label]")) {
    el.setAttribute("aria-label", t(el.dataset.i18nAriaLabel));
  }
}
