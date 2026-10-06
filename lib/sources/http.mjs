// Shared HTTP helper for sources.

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** GET a page as text; resolves to null on 404. Retries transient failures. */
export async function fetchText(url, { encoding = 'utf-8', retries = 2 } = {}) {
  const decoder = new TextDecoder(encoding);
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await fetch(url, { headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(25000) });
      if (res.status === 404) return null;
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return decoder.decode(await res.arrayBuffer());
    } catch (err) {
      if (attempt >= retries) throw new Error(`${url}: ${err.message}`);
      await sleep(800 * (attempt + 1));
    }
  }
}
