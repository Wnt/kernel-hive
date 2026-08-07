#!/usr/bin/env python3
"""model-review — tiny LAN judging UI for scene-v2 model candidates.

The director opens http://<devbox>:5197, sees subjects with one or more
candidate renders (produced by the SceneV2 lineup harness so lighting matches
the museum), picks a candidate (or keep/bench for single-candidate subjects)
and leaves comments. Verdicts append to verdicts.jsonl, which the agent reads
to drive the next modeling iteration.

Data layout (default root ~/scene-v2-reference/review):
  candidates/<subject>/<variant>.png   render(s) for one subject
  candidates/<subject>/meta.json      {"question": str, "notes": str}
  verdicts.jsonl                       one JSON per saved verdict

Run: python3 scripts/dev/model-review.py [--port 5197] [--root DIR]
"""

import argparse
import json
import sys
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PAGE = """<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>scene-v2 model review</title>
<style>
 body{background:#16181c;color:#e8e6e0;font:15px/1.5 system-ui;margin:0;padding:24px}
 h1{font-size:20px} h2{font-size:16px;margin:28px 0 8px}
 .subject{border:1px solid #333;border-radius:10px;padding:16px;margin:18px 0;background:#1d2026}
 .cands{display:flex;gap:12px;flex-wrap:wrap}
 .cand{border:2px solid #444;border-radius:8px;max-width:640px}
 .cand img{width:100%;display:block;border-radius:6px;cursor:zoom-in}
 .cand .pick{display:block;width:100%;background:#333;border:0;color:#ddd;
   padding:6px;cursor:pointer;border-radius:0 0 6px 6px}
 .cand.sel .pick{background:#2f6fbd;color:#fff}
 #lb{position:fixed;inset:0;background:rgba(0,0,0,.92);display:none;
   align-items:center;justify-content:center;cursor:zoom-out;z-index:9}
 #lb img{max-width:98vw;max-height:98vh}
 .cand .lbl{padding:4px 8px;font-size:13px;color:#aaa}
 .cand.sel{border-color:#4da3ff}
 textarea{width:100%;box-sizing:border-box;background:#111;border:1px solid #333;
   border-radius:6px;color:#e8e6e0;padding:8px;margin-top:10px;min-height:40px}
 button{background:#2f6fbd;border:0;border-radius:6px;color:#fff;padding:8px 18px;
   margin-top:8px;cursor:pointer;font-size:14px}
 button.bench{background:#7a3b3b;margin-left:8px}
 .done{color:#7fd27f;font-size:13px;margin-left:10px}
 .q{color:#c9c4b8}
 details{margin-top:32px}
 summary{font-size:16px;font-weight:600;cursor:pointer;padding:8px 0}
</style>
<h1>scene-v2 · model review · v3</h1>
<div id=app>loading…</div>
<div id=lb onclick="this.style.display='none'"><img></div>
<script>
async function load(){
  const s=await (await fetch('api/state')).json();
  render(s);
}
function render(s){
  const app=document.getElementById('app');app.innerHTML='';
  const pending=s.subjects.filter(sub=>!s.verdicts[sub.name]);
  const archived=s.subjects.filter(sub=>s.verdicts[sub.name]);
  const todo=document.createElement('section');
  todo.innerHTML=`<h2>To judge (${pending.length})</h2>`;
  for(const sub of pending)todo.appendChild(card(sub,s.verdicts[sub.name]));
  app.appendChild(todo);
  const old=document.createElement('details');
  old.innerHTML=`<summary>Archived (${archived.length})</summary>`;
  for(const sub of archived)old.appendChild(card(sub,s.verdicts[sub.name]));
  app.appendChild(old);
}
function card(sub,v){
    const d=document.createElement('div');d.className='subject';
    d.innerHTML=`<h2>${sub.name}</h2><div class=q>${sub.question||''}</div>`;
    const c=document.createElement('div');c.className='cands';
    for(const cand of sub.candidates){
      const el=document.createElement('div');el.className='cand';el.dataset.v=cand;
      if(v&&v.pick===cand)el.classList.add('sel');
      const lbl=cand.replace('.png','');
      el.innerHTML=`<img loading=lazy src="img/${sub.name}/${cand}">`+
        `<div class=lbl>${lbl}</div><button class=pick>select</button>`;
      el.querySelector('img').onclick=(e)=>{e.stopPropagation();const lb=document.getElementById('lb');
        lb.querySelector('img').src=`img/${sub.name}/${cand}`;lb.style.display='flex'};
      el.querySelector('.pick').onclick=()=>{c.querySelectorAll('.cand').forEach(x=>x.classList.remove('sel'));el.classList.add('sel')};
      c.appendChild(el);
    }
    d.appendChild(c);
    const t=document.createElement('textarea');t.placeholder='comments for the modeler…';
    if(v&&v.comment)t.value=v.comment;d.appendChild(t);
    const ok=document.createElement('button');ok.textContent=sub.candidates.length>1?'Pick selected':'Keep';
    const no=document.createElement('button');no.textContent='Bench';no.className='bench';
    const mark=document.createElement('span');mark.className='done';
    if(v)mark.textContent=`saved ✓ ${v.pick} ${v.comment?'· "'+v.comment+'"':''}`;
    ok.onclick=async()=>{
      const sel=c.querySelector('.sel');
      const pick=sub.candidates.length>1?(sel?sel.dataset.v:null):'keep';
      if(!pick){alert('select a candidate first');return}
      await save(sub.name,pick,t.value,mark);
    };
    no.onclick=async()=>{await save(sub.name,'bench',t.value,mark);};
    d.appendChild(ok);d.appendChild(no);d.appendChild(mark);
    return d;
}
async function save(subject,pick,comment,mark){
  try{
    const r=await fetch('api/verdict',{method:'POST',headers:{'content-type':'application/json'},
      body:JSON.stringify({subject,pick,comment})});
    if(!r.ok)throw new Error('http '+r.status);
    const chk=await (await fetch('api/state')).json();
    const v=chk.verdicts[subject];
    if(v&&v.pick===pick){
      mark.style.color='#7fd27f';mark.textContent=`saved ✓ ${v.pick}`;
      render(chk);
    }
    else throw new Error('not in server state');
  }catch(e){
    mark.style.color='#ff8080';mark.textContent='SAVE FAILED ('+e.message+') — retry';
  }
}
load();
</script>"""


class Handler(BaseHTTPRequestHandler):
    root: Path  # set on the server class before serving

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def do_GET(self):  # noqa: N802 (http.server API)
        if self.path in ("/", "/index.html"):
            return self._send(200, PAGE)
        if self.path == "/api/state":
            return self._send(200, json.dumps(self.state()), "application/json")
        if self.path.startswith("/img/"):
            rel = self.path[len("/img/") :]
            f = (self.root / "candidates" / rel).resolve()
            if f.is_file() and f.suffix == ".png" and f.is_relative_to(self.root.resolve()):
                return self._send(200, f.read_bytes(), "image/png")
        return self._send(404, "not found")

    def do_POST(self):  # noqa: N802 (http.server API)
        if self.path != "/api/verdict":
            return self._send(404, "not found")
        try:
            n = int(self.headers.get("content-length", 0))
            if n <= 0:
                raise ValueError("missing JSON body")
            rec = json.loads(self.rfile.read(n))
            if not isinstance(rec, dict):
                raise ValueError("JSON body must be an object")
        except (UnicodeDecodeError, ValueError):
            body = json.dumps({"error": "invalid or missing JSON body"})
            return self._send(400, body, "application/json")
        rec["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        with open(self.root / "verdicts.jsonl", "a") as f:
            f.write(json.dumps(rec) + "\n")
        return self._send(200, "{}", "application/json")

    def state(self):
        subjects = []
        cdir = self.root / "candidates"
        if cdir.is_dir():
            for sub in sorted(p for p in cdir.iterdir() if p.is_dir()):
                meta = {}
                mf = sub / "meta.json"
                if mf.is_file():
                    meta = json.loads(mf.read_text())
                cands = sorted(p.name for p in sub.glob("*.png"))
                if cands:
                    subjects.append({"name": sub.name, "question": meta.get("question", ""), "candidates": cands})
        verdicts = {}
        vf = self.root / "verdicts.jsonl"
        if vf.is_file():
            for line in vf.read_text().splitlines():
                if line.strip():
                    rec = json.loads(line)
                    verdicts[rec["subject"]] = rec  # last write wins
        return {"version": 3, "subjects": subjects, "verdicts": verdicts}

    def log_message(self, fmt, *args):
        timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
        print(f"{timestamp} {self.client_address[0]} {fmt % args}", file=sys.stderr, flush=True)


def main():
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5197)
    ap.add_argument("--root", default=str(Path.home() / "scene-v2-reference/review"))
    args = ap.parse_args()
    Handler.root = Path(args.root)
    (Handler.root / "candidates").mkdir(parents=True, exist_ok=True)
    srv = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"model-review on http://0.0.0.0:{args.port} root={Handler.root}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
