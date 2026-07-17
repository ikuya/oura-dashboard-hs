export async function apiFetch(url, options = {}) {
  const res = await fetch(url, options);
  if (res.status === 401) {
    window.showLoginModal();
    throw new Error("Unauthorized");
  }
  return res;
}
