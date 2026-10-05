"""Download free XAUUSD 1-minute BID candles from Dukascopy.

Usage:
    python download_dukascopy.py --start 2023-01-01 --end 2026-10-03 --out data/m1

Each trading day is saved as <out>/<YYYY-MM-DD>.bin (raw, decompressed
Dukascopy candle records: >IIIIIf = sec-of-day, open, close, low, high, volume;
prices are integers / 1000). Days already on disk are skipped, so the script
can be stopped and restarted at any time. Dukascopy rate-limits (HTTP 429),
the script backs off automatically.
"""
import argparse
import datetime as dt
import lzma
import os
import random
import ssl
import time
import urllib.error
import urllib.request

URL = "https://datafeed.dukascopy.com/datafeed/XAUUSD/{y}/{m:02d}/{d:02d}/BID_candles_min_1.bi5"


def build_opener():
    handlers = []
    proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"https": proxy}))
    cafile = os.environ.get("SSL_CERT_FILE")
    ctx = ssl.create_default_context(cafile=cafile) if cafile else ssl.create_default_context()
    handlers.append(urllib.request.HTTPSHandler(context=ctx))
    return urllib.request.build_opener(*handlers)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", default="2023-01-01")
    ap.add_argument("--end", default=dt.date.today().isoformat())
    ap.add_argument("--out", default="data/m1")
    ap.add_argument("--reverse", action="store_true", help="download newest days first")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    opener = build_opener()
    start = dt.date.fromisoformat(args.start)
    end = dt.date.fromisoformat(args.end)
    days = [start + dt.timedelta(days=i) for i in range((end - start).days + 1)]
    if args.reverse:
        days.reverse()

    for d in days:
        if d.weekday() == 5:  # Saturday: market closed
            continue
        fn = os.path.join(args.out, f"{d.isoformat()}.bin")
        if os.path.exists(fn):
            continue
        # Dukascopy months are 0-based
        url = URL.format(y=d.year, m=d.month - 1, d=d.day)
        delay = 2.0
        for _ in range(12):
            try:
                data = opener.open(url, timeout=40).read()
                raw = lzma.decompress(data) if data else b""
                with open(fn, "wb") as f:
                    f.write(raw)
                print(d, len(raw) // 24, flush=True)
                break
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    open(fn, "wb").close()
                    print(d, "404", flush=True)
                    break
                time.sleep(delay + random.random())
                delay = min(delay * 2, 60)
            except Exception as e:  # network hiccup
                print(d, "error", e, flush=True)
                time.sleep(delay)
                delay = min(delay * 2, 60)
        time.sleep(3.0)
    print("DONE")


if __name__ == "__main__":
    main()
