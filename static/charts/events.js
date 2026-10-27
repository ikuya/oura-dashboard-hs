import { SERIES_BLUE, SERIES_ORANGE, SERIES_AQUA, addDaysStr, rangeDays,
         valuesByDay, dayWithWeekday } from "./common.js";
import { nightlyVitalsRows } from "./vitals.js";

// --- Tags, workouts and sessions ---

// `events` is /api/events: { tags, workouts, sessions }, each in the order
// they started. A tag carries start_day / end_day; the others a day.

// "tag_sleep_alcohol" → "Alcohol", "strengthTraining" → "Strength training".
const TAG_PREFIXES = /^tag_(generic_|sleep_|activity_)?/;
const TAG_NAMES = { nocaffeine: "No caffeine" };

function humanize(code) {
  const words = code.replace(/([a-z])([A-Z])/g, "$1 $2").replaceAll("_", " ").toLowerCase();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

export function tagLabel(tag) {
  if (tag.custom_name) return tag.custom_name;
  const code = (tag.tag_type_code ?? "tag").replace(TAG_PREFIXES, "");
  return TAG_NAMES[code] ?? humanize(code);
}

export const activityLabel = (workout) => humanize(workout.activity ?? "workout");

// Every day a tag covers: from its start_day through its end_day, if any.
export function tagDays(tag) {
  return rangeDays(tag.start_day, tag.end_day ?? tag.start_day);
}

// The recorded wall-clock "HH:MM" of an ISO timestamp, kept in its own offset
// like the sleep times.
const clockOf = (iso) => (iso ? iso.slice(11, 16) : null);

export function eventMinutes(e) {
  if (!e.start_datetime || !e.end_datetime) return null;
  return Math.round((new Date(e.end_datetime) - new Date(e.start_datetime)) / 60000);
}

// Day → the workouts that started on it.
export function workoutsByDay(workouts) {
  const byDay = new Map();
  for (const w of workouts) byDay.set(w.day, [...(byDay.get(w.day) ?? []), w]);
  return byDay;
}

// Day → the labels of the tags covering it, each once.
export function tagLabelsByDay(tags) {
  const byDay = new Map();
  for (const t of tags) {
    for (const day of tagDays(t)) byDay.set(day, new Set([...(byDay.get(day) ?? []), tagLabel(t)]));
  }
  return byDay;
}

// One timeline row per tag label, workout activity and session type seen in
// the range, each a map of day → what happened that day.
function timelineRows(events, days) {
  const inRange = new Set(days);
  const rows = new Map();
  const add = (key, label, color, day, entry) => {
    if (!inRange.has(day)) return;
    if (!rows.has(key)) rows.set(key, { label, color, byDay: new Map() });
    const byDay = rows.get(key).byDay;
    byDay.set(day, [...(byDay.get(day) ?? []), entry]);
  };
  for (const t of events.tags ?? []) {
    const label = tagLabel(t);
    const text = [label, clockOf(t.start_time), t.comment].filter(Boolean).join(" ");
    for (const day of tagDays(t)) add(`tag:${label}`, label, SERIES_ORANGE, day, { text });
  }
  for (const w of events.workouts ?? []) {
    const label = activityLabel(w);
    const minutes = eventMinutes(w);
    const text = [label, clockOf(w.start_datetime), minutes != null && `${minutes} min`,
                  w.calories != null && `${Math.round(w.calories)} kcal`, w.intensity]
      .filter(Boolean).join(" ");
    add(`workout:${label}`, label, SERIES_AQUA, w.day, { text, minutes });
  }
  for (const s of events.sessions ?? []) {
    const label = `${humanize(s.type ?? "session")} session`;
    const minutes = eventMinutes(s);
    const text = [label, clockOf(s.start_datetime), minutes != null && `${minutes} min`, s.mood]
      .filter(Boolean).join(" ");
    add(`session:${label}`, label, SERIES_BLUE, s.day, { text, minutes });
  }
  return [...rows.values()];
}

// A workout or session cell deepens with its length, full at an hour; a tag
// is either there or not.
function cellAlpha(entries) {
  const minutes = entries.reduce((total, e) => total + (e.minutes ?? 0), 0);
  return entries.some((e) => e.minutes != null) ? 0.35 + 0.65 * Math.min(minutes / 60, 1) : 0.9;
}

const hexAlpha = (alpha) => Math.round(alpha * 255).toString(16).padStart(2, "0");

// Rows are what happened, columns every day of the range, laid out like the
// contributor heatmaps. Pointing at or tapping a cell names it below the grid.
export function renderEventTimeline(events, state) {
  const box = document.getElementById("events-timeline");
  const detail = document.getElementById("events-timeline-detail");
  if (!box || !state.rangeStart || !state.rangeEnd) return;
  const days = rangeDays(state.rangeStart, state.rangeEnd);
  const rows = timelineRows(events, days);
  if (rows.length === 0) {
    box.replaceChildren();
    detail.textContent = "No tags, workouts or sessions in this range";
    return;
  }
  const gap = days.length <= 31 ? 2 : days.length <= 90 ? 1 : 0;

  const grid = document.createElement("div");
  grid.className = "heatmap-grid";
  grid.style.gridTemplateColumns = `var(--heatmap-label-width) repeat(${days.length}, minmax(0, 1fr))`;
  grid.style.gridTemplateRows = `repeat(${rows.length}, 20px) auto`;
  grid.style.gap = `${gap}px`;

  for (const row of rows) {
    const label = document.createElement("div");
    label.className = "heatmap-label";
    label.textContent = row.label;
    label.style.color = row.color;
    grid.append(label);
    for (const day of days) {
      const entries = row.byDay.get(day);
      const cell = document.createElement("div");
      cell.className = "heatmap-cell";
      cell.dataset.text = `${dayWithWeekday(day)} · ${entries ? entries.map((e) => e.text).join(", ") : `no ${row.label}`}`;
      if (entries) cell.style.background = row.color + hexAlpha(cellAlpha(entries));
      grid.append(cell);
    }
  }

  const axis = document.createElement("div");
  axis.className = "heatmap-axis";
  axis.style.gridColumn = "2 / -1";
  const mid = days[Math.floor((days.length - 1) / 2)];
  axis.append(...[days[0], mid, days[days.length - 1]].map((day) => {
    const tick = document.createElement("span");
    tick.textContent = day.slice(5);
    return tick;
  }));
  grid.append(document.createElement("div"), axis);

  let selected = null;
  const select = (e) => {
    const cell = e.target.closest(".heatmap-cell");
    if (!cell || cell === selected) return;
    selected?.classList.remove("selected");
    cell.classList.add("selected");
    selected = cell;
    detail.textContent = cell.dataset.text;
  };
  grid.addEventListener("pointerover", select);
  grid.addEventListener("click", select);

  box.replaceChildren(grid);
  detail.textContent = "Tap a cell for what happened";
}

// --- The morning after a tag ---

// What a tagged day is set against: the next morning's scores and the night's
// HRV, all dated by that morning (day D's evening tag meets day D+1).
const EFFECT_OUTCOMES = [
  { label: "Readiness", byDay: ({ metrics }) => valuesByDay(metrics.readiness ?? [], (r) => r.score), digits: 0 },
  { label: "Sleep", byDay: ({ metrics }) => valuesByDay(metrics.sleep ?? [], (r) => r.score), digits: 0 },
  { label: "Night HRV", byDay: ({ periods }) => valuesByDay(nightlyVitalsRows(periods), (r) => r.hrv), digits: 0, unit: " ms" },
];

const mean = (values) => (values.length ? values.reduce((a, b) => a + b, 0) / values.length : null);

// Per tag label (and "Any workout"), the mean of each outcome on the mornings
// after the days it was on, against the mean after the other days. The days
// are those whose next morning falls in the range, as in Next-Day Effects.
export function tagEffects(events, source, rangeStart, rangeEnd) {
  const causeDays = rangeDays(addDaysStr(rangeStart, -1), addDaysStr(rangeEnd, -1));
  const tagsByDay = tagLabelsByDay(events.tags ?? []);
  const workoutDays = new Set((events.workouts ?? []).map((w) => w.day));
  const groups = new Map();
  for (const day of causeDays) {
    for (const label of tagsByDay.get(day) ?? []) groups.set(label, [...(groups.get(label) ?? []), day]);
    if (workoutDays.has(day)) groups.set("Any workout", [...(groups.get("Any workout") ?? []), day]);
  }
  const outcomes = EFFECT_OUTCOMES.map((o) => ({ ...o, values: o.byDay(source) }));

  return [...groups].map(([label, tagged]) => {
    const isTagged = new Set(tagged);
    return {
      label,
      days: tagged.length,
      outcomes: outcomes.map((o) => {
        const after = (days) => days.flatMap((d) => {
          const v = o.values.get(addDaysStr(d, 1));
          return v == null ? [] : [v];
        });
        const withTag = after(tagged);
        const others = after(causeDays.filter((d) => !isTagged.has(d)));
        return { ...o, mean: mean(withTag), n: withTag.length, others: mean(others) };
      }),
    };
  }).sort((a, b) => b.days - a.days);
}

const signed = (d, digits) => {
  const r = Number(d.toFixed(digits));
  return `${r > 0 ? "+" : r < 0 ? "−" : "±"}${Math.abs(r).toFixed(digits)}`;
};

// With only a night or two behind it a difference is mostly noise, so it is
// shown greyed until there are a few.
const MIN_EFFECT_NIGHTS = 3;

export function renderTagEffects(events, source, state) {
  const box = document.getElementById("tag-effects");
  if (!box || !state.rangeStart || !state.rangeEnd) return;
  const rows = tagEffects(events, source, state.rangeStart, state.rangeEnd);
  if (rows.length === 0) {
    box.textContent = "No tags or workouts in this range";
    return;
  }

  const el = (tag, text, className) => Object.assign(document.createElement(tag), { textContent: text ?? "", className: className ?? "" });
  const table = el("table", null, "effects-table");
  const head = table.createTHead().insertRow();
  head.append(el("th", ""), el("th", "Days"), ...EFFECT_OUTCOMES.map((o) => el("th", o.label)));
  const body = table.createTBody();
  for (const row of rows) {
    const tr = body.insertRow();
    tr.append(el("td", row.label), el("td", String(row.days)));
    for (const o of row.outcomes) {
      const td = el("td");
      if (o.mean == null) {
        td.textContent = "—";
      } else {
        td.append(el("span", `${o.mean.toFixed(o.digits)}${o.unit ?? ""}`));
        if (o.others != null) {
          const diff = o.mean - o.others;
          const tone = o.n < MIN_EFFECT_NIGHTS ? "few" : diff > 0 ? "up" : diff < 0 ? "down" : "";
          td.append(el("span", ` ${signed(diff, 1)}`, `effects-diff ${tone}`));
        }
        td.title = `n=${o.n}; other days ${o.others == null ? "—" : o.others.toFixed(1)}`;
      }
      tr.append(td);
    }
  }
  box.replaceChildren(table);
}
