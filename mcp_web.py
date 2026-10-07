#!/usr/bin/env python3
"""Mini MCP stdio server: web_fetch + web_search untuk pico_claw."""
import sys, json, urllib.request, urllib.parse, re, html as h

HEADERS = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) pico-mcp/1.0"}

def fetch(url):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=25) as r:
        data = r.read(2_000_000).decode("utf-8", "replace")
    # strip tags sederhana
    data = re.sub(r"<script[\s\S]*?</script>|<style[\s\S]*?</style>", " ", data)
    text = re.sub(r"<[^>]+>", " ", data)
    text = h.unescape(re.sub(r"\s+", " ", text)).strip()
    return {"url": url, "text": text[:12000]}

def search(q):
    url = "https://html.duckduckgo.com/html/?q=" + urllib.parse.quote(q)
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=25) as r:
        data = r.read(500_000).decode("utf-8", "replace")
    results = []
    for m in re.finditer(r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', data):
        href, title = m.group(1), re.sub(r"<[^>]+>", "", m.group(2))
        if "uddg=" in href:
            href = urllib.parse.unquote(href.split("uddg=")[1].split("&")[0])
        results.append({"title": h.unescape(title).strip(), "url": href})
        if len(results) >= 8: break
    return {"query": q, "results": results}

TOOLS = {
    "web_fetch": {"description": "Fetch a URL and return readable text", "args": {"url": "string, required"}},
    "web_search": {"description": "Web search (DuckDuckGo), returns titles+urls", "args": {"query": "string, required"}},
}

def call(name, args):
    if name == "web_fetch":
        return fetch(args["url"])
    if name == "web_search":
        return search(args["query"])
    raise ValueError("unknown tool")

for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method = msg.get("method")
    mid = msg.get("id")
    def reply(result): print(json.dumps({"jsonrpc":"2.0","id":mid,"result":result}), flush=True)
    if method == "initialize":
        reply({"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"pico-web","version":"1.0.0"}})
    elif method == "tools/list":
        reply({"tools":[{"name":k,"description":v["description"],"inputSchema":{"type":"object","properties":{a:{"type":"string"} for a in v["args"]},"required":list(v["args"])}} for k,v in TOOLS.items()]})
    elif method == "tools/call":
        p = msg.get("params", {})
        try:
            out = call(p.get("name"), p.get("arguments", {}))
            reply({"content":[{"type":"text","text":json.dumps(out, ensure_ascii=False)}]})
        except Exception as e:
            print(json.dumps({"jsonrpc":"2.0","id":mid,"error":{"code":-32000,"message":str(e)}}), flush=True)
    elif method == "notifications/initialized":
        pass
