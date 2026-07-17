export function localDateStr(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

export function todayStr() {
  return localDateStr();
}

export function daysAgoStr(n) {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return localDateStr(d);
}

export function scoreColor(v) {
  if (v == null) return "#6b7280";
  if (v >= 80) return "#22c55e";
  if (v >= 60) return "#eab308";
  return "#ef4444";
}

export function scoreClass(v) {
  if (v == null) return "score-neutral";
  if (v >= 80) return "score-green";
  if (v >= 60) return "score-yellow";
  return "score-red";
}

export function setStatus(msg, isError = false) {
  const el = document.getElementById("status-bar");
  el.textContent = msg;
  el.className = isError ? "error" : "";
}
