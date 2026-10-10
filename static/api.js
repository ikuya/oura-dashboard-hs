// The server's CSRF middleware sets this cookie and expects it echoed back in
// a header on every non-GET request.
function csrfToken() {
  const m = document.cookie.match(/(?:^|;\s*)XSRF-TOKEN=([^;]*)/);
  return m ? decodeURIComponent(m[1]) : "";
}

export async function apiFetch(url, options = {}) {
  const method = (options.method || "GET").toUpperCase();
  const headers = method === "GET"
    ? options.headers
    : { ...options.headers, "X-XSRF-TOKEN": csrfToken() };
  const res = await fetch(url, { ...options, headers });
  if (res.status === 401) {
    location.href = "/login";
    throw new Error("Unauthorized");
  }
  return res;
}
