# ✅ Full bootstrap script (writes the **entire** repo)

Save this as **`bootstrap-quantasport-oss.ps1`** in your repo root. This is the complete version that generates **all** files and folders (compose, services, scripts, manifest, README, etc.) and can start Docker.

```powershell
# bootstrap-quantasport-oss.ps1
# One-file setup: run once to create ALL required files/folders for the Quantasport OSS stack.
# Usage (PowerShell):
#   1) Save this file as bootstrap-quantasport-oss.ps1 in your repo root
#   2) Open PowerShell in the repo folder and run:
#        Set-ExecutionPolicy -Scope Process Bypass -Force
#        ./bootstrap-quantasport-oss.ps1 -Run
#      (omit -Run if you only want to write files without starting Docker)

param(
  [switch]$Run
)

$ErrorActionPreference = 'Stop'

function Write-File($Path, $Content) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $Content | Out-File -FilePath $Path -Encoding UTF8 -Force
  Write-Host "Wrote $Path"
}

# -----------------------------
# File payloads
# -----------------------------
$files = @(
  @{ Path = ".env.example"; Content = @'
ENABLE_ANCHOR=false
ANCHOR_INTERVAL_SECONDS=0
'@ },

  @{ Path = "docker-compose.yml"; Content = @'
version: "3.9"

services:
  api:
    build: ./services/api
    container_name: qs_api
    ports:
      - "8000:8000"
    environment:
      - AUDIT_DATA_DIR=/data
    volumes:
      - ./shared/audit-data:/data
    restart: unless-stopped

  audit:
    build: ./services/audit
    container_name: qs_audit
    environment:
      - AUDIT_DATA_DIR=/data
      - ENABLE_ANCHOR=${ENABLE_ANCHOR:-false}
      - ANCHOR_INTERVAL_SECONDS=${ANCHOR_INTERVAL_SECONDS:-0}
    volumes:
      - ./shared/audit-data:/data
    depends_on:
      - api
    restart: unless-stopped

  ui:
    build: ./services/ui
    container_name: qs_ui
    ports:
      - "8501:8501"
    environment:
      - AUDIT_DATA_DIR=/data
      - API_BASE=http://api:8000
    volumes:
      - ./shared/audit-data:/data:ro
    depends_on:
      - api
      - audit
    restart: unless-stopped
'@ },

  @{ Path = "manifest.json"; Content = @'
{
  "name": "Quantasport GPT-OSS Audit Stack",
  "version": "0.1.0",
  "description": "Local/offline-capable Quantasport stack with FastAPI backend, Streamlit dashboard, append-only hash chain, and optional blockchain anchoring (OpenTimestamps, Chainpoint).",
  "author": "Dayok / Quantasport",
  "license": "MIT",
  "main": "index.js",
  "scripts": {
    "start": "docker compose up --build",
    "stop": "docker compose down",
    "audit:verify": "python scripts/verify_chain.py",
    "anchor:ots": "python scripts/submit_ots.py",
    "anchor:chainpoint": "python scripts/submit_chainpoint.py"
  },
  "dependencies": {
    "fastapi": ">=0.110.0",
    "uvicorn": ">=0.27.1",
    "pydantic": ">=2.6.1",
    "streamlit": ">=1.32.0",
    "requests": ">=2.31.0",
    "pandas": ">=2.2.1",
    "watchdog": ">=4.0.0",
    "python-dateutil": ">=2.9.0",
    "pyopenssl": ">=24.0.0"
  },
  "optionalDependencies": {
    "opentimestamps-client": ">=0.7.0",
    "chainpoint-client": ">=1.0.0"
  },
  "config": {
    "enableAnchor": false,
    "anchorIntervalSeconds": 0,
    "anchorProviders": ["OpenTimestamps", "Chainpoint"],
    "auditDataDir": "./shared/audit-data"
  }
}
'@ },

  @{ Path = "README.md"; Content = @'
# Quantasport OSS + Audit

## Run
1. `cp .env.example .env`
2. `docker compose up -d --build`
3. API docs: http://localhost:8000/docs · UI: http://localhost:8501

## Config
- `ENABLE_ANCHOR=true` to emit anchor payloads to `shared/audit-data/anchors/`.
- `ANCHOR_INTERVAL_SECONDS=3600` to auto-write once per hour (0 for manual only).

## Verify Integrity
- Records form an append-only hash chain (each entry stores `prev` tip hash).
- Anchor files capture the chain tip hash at a point in time for 3rd-party timestamping.
'@ },

  # services/api
  @{ Path = "services/api/Dockerfile"; Content = @'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
'@ },
  @{ Path = "services/api/requirements.txt"; Content = @'
fastapi==0.110.0
uvicorn[standard]==0.27.1
pydantic==2.6.1
'@ },
  @{ Path = "services/api/app.py"; Content = @'
import os, json, time
from pathlib import Path
from fastapi import FastAPI, Body
from pydantic import BaseModel, Field
from typing import Any, Dict

DATA_DIR = Path(os.getenv("AUDIT_DATA_DIR", "/data"))
INBOX = DATA_DIR / "inbox"
ANCHOR_REQUESTS = DATA_DIR / "anchor_requests"
for p in (INBOX, ANCHOR_REQUESTS):
    p.mkdir(parents=True, exist_ok=True)

class AuditEvent(BaseModel):
    action: str = Field(..., min_length=1)
    actor: str = Field(..., min_length=1)
    resource: str = Field(..., min_length=1)
    metadata: Dict[str, Any] = {}

app = FastAPI(title="Quantasport OSS API", version="0.1")

@app.get("/health")
def health():
    return {"ok": True, "ts": int(time.time())}

@app.post("/audit/log")
def log_event(event: AuditEvent = Body(...)):
    INBOX.mkdir(parents=True, exist_ok=True)
    payload = {
        "ts": int(time.time()),
        **event.model_dump(),
    }
    with open(INBOX / "events.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(payload, ensure_ascii=False) + "\n")
    return {"status": "queued", "event": payload}

@app.post("/audit/anchor")
def request_anchor():
    ANCHOR_REQUESTS.mkdir(parents=True, exist_ok=True)
    req = {"ts": int(time.time()), "reason": "manual"}
    path = ANCHOR_REQUESTS / f"anchor_request_{req['ts']}.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(req, f)
    return {"status": "accepted", "request": req}
'@ },

  # services/audit
  @{ Path = "services/audit/Dockerfile"; Content = @'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY service.py ./
CMD ["python", "service.py"]
'@ },
  @{ Path = "services/audit/requirements.txt"; Content = @'
watchdog==4.0.0
'@ },
  @{ Path = "services/audit/service.py"; Content = @'
import os, json, time, hashlib
from pathlib import Path
from typing import Optional

DATA_DIR = Path(os.getenv("AUDIT_DATA_DIR", "/data"))
INBOX = DATA_DIR / "inbox" / "events.jsonl"
CHAIN_DIR = DATA_DIR / "chain"
ANCHORS_DIR = DATA_DIR / "anchors"
REQUESTS_DIR = DATA_DIR / "anchor_requests"
ENABLE_ANCHOR = os.getenv("ENABLE_ANCHOR", "false").lower() == "true"
ANCHOR_INTERVAL_SECONDS = int(os.getenv("ANCHOR_INTERVAL_SECONDS", "0"))

for p in (CHAIN_DIR, ANCHORS_DIR, REQUESTS_DIR):
    p.mkdir(parents=True, exist_ok=True)

CHAIN_FILE = CHAIN_DIR / "audit_chain.jsonl"
STATE_FILE = CHAIN_DIR / "state.json"

def sha256_hex(s: bytes) -> str:
    return hashlib.sha256(s).hexdigest()

def get_tip() -> Optional[dict]:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            return None
    return None

def append_event(ev: dict):
    tip = get_tip()
    prev_hash = tip["hash"] if tip else "0"*64
    entry = {
        "seq": (tip["seq"] + 1) if tip else 1,
        "ts": ev["ts"],
        "prev": prev_hash,
        "event": ev,
    }
    entry_bytes = json.dumps(entry, separators=(",", ":"), sort_keys=True).encode("utf-8")
    entry_hash = sha256_hex(entry_bytes)
    record = {"hash": entry_hash, **entry}
    with open(CHAIN_FILE, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")
    STATE_FILE.write_text(json.dumps({"seq": record["seq"], "hash": entry_hash}))

def read_new_events(last_offset: int):
    if not INBOX.exists():
        return last_offset, []
    events = []
    with open(INBOX, "r", encoding="utf-8") as f:
        f.seek(last_offset)
        for line in f:
            try:
                events.append(json.loads(line))
            except Exception:
                continue
        last_offset = f.tell()
    return last_offset, events

def write_anchor(reason: str = "timer"):
    tip = get_tip()
    if not tip:
        return
    anchor = {
        "ts": int(time.time()),
        "reason": reason,
        "seq": tip["seq"],
        "tip_hash": tip["hash"],
        "advice": "Submit tip_hash to your chosen timestamping network (e.g., OpenTimestamps). Keep this file as your local receipt.",
    }
    path = ANCHORS_DIR / f"anchor_{anchor['ts']}_{anchor['seq']}.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(anchor, f, indent=2)

def handle_anchor_requests():
    for p in REQUESTS_DIR.glob("anchor_request_*.json"):
        try:
            write_anchor("manual")
        finally:
            try:
                p.unlink()
            except Exception:
                pass

def main():
    last_offset = 0
    last_anchor = time.time()
    while True:
        last_offset, new_events = read_new_events(last_offset)
        for ev in new_events:
            append_event(ev)
        handle_anchor_requests()
        if ENABLE_ANCHOR and ANCHOR_INTERVAL_SECONDS > 0:
            if time.time() - last_anchor >= ANCHOR_INTERVAL_SECONDS:
                write_anchor("timer")
                last_anchor = time.time()
        time.sleep(0.5)

if __name__ == "__main__":
    main()
'@ },

  # services/ui
  @{ Path = "services/ui/Dockerfile"; Content = @'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY streamlit_app.py ./
EXPOSE 8501
CMD ["streamlit", "run", "streamlit_app.py", "--server.port", "8501", "--server.address", "0.0.0.0"]
'@ },
  @{ Path = "services/ui/requirements.txt"; Content = @'
streamlit==1.32.0
requests==2.31.0
pandas==2.2.1
'@ },
  @{ Path = "services/ui/streamlit_app.py"; Content = @'
import os, json
from pathlib import Path
import pandas as pd
import requests
import streamlit as st

DATA_DIR = Path(os.getenv("AUDIT_DATA_DIR", "/data"))
API_BASE = os.getenv("API_BASE", "http://localhost:8000")
CHAIN_FILE = DATA_DIR / "chain" / "audit_chain.jsonl"
ANCHORS_DIR = DATA_DIR / "anchors"

st.set_page_config(page_title="Quantasport Audit", layout="wide")
st.title("Quantasport – Audit Trail")

cols = st.columns(3)
with cols[0]:
    if st.button("Send Sample Event"):
        r = requests.post(f"{API_BASE}/audit/log", json={
            "action": "SAMPLE",
            "actor": "ui",
            "resource": "demo",
            "metadata": {"note": "from streamlit"}
        })

with cols[1]:
    if st.button("Anchor Now"):
        requests.post(f"{API_BASE}/audit/anchor")

with cols[2]:
    st.markdown("**Anchoring** creates a timestamped tip hash file. Submit it later to a public network if required.")

st.subheader("Chain Tip")
state_path = DATA_DIR / "chain" / "state.json"
if state_path.exists():
    tip = json.loads(state_path.read_text())
    st.code(json.dumps(tip, indent=2))
else:
    st.info("No events yet – send one above.")

st.subheader("Chain Records")
rows = []
if CHAIN_FILE.exists():
    with open(CHAIN_FILE, "r", encoding="utf-8") as f:
        for line in f:
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
if rows:
    df = pd.DataFrame(rows)
    st.dataframe(df, use_container_width=True)

st.subheader("Anchors")
anchor_rows = []
if ANCHORS_DIR.exists():
    for p in sorted(ANCHORS_DIR.glob("anchor_*.json")):
        try:
            anchor_rows.append(json.loads(p.read_text()))
        except Exception:
            pass
if anchor_rows:
    adf = pd.DataFrame(anchor_rows)
    st.dataframe(adf, use_container_width=True)
'@ },

  # scripts
  @{ Path = "scripts/verify_chain.py"; Content = @'
#!/usr/bin/env python3
import json, hashlib, sys
from pathlib import Path

CHAIN_FILE = Path("shared/audit-data/chain/audit_chain.jsonl")

def sha256_hex(s: bytes) -> str:
    return hashlib.sha256(s).hexdigest()

def main():
    if not CHAIN_FILE.exists():
        print("No chain found:", CHAIN_FILE)
        sys.exit(1)
    prev = "0"*64
    ok = True
    with open(CHAIN_FILE, "r", encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            rec = json.loads(line)
            if rec["prev"] != prev:
                print(f"[FAIL] seq {i}: prev mismatch")
                ok = False
            entry = {k: rec[k] for k in ("seq","ts","prev","event")}
            entry_bytes = json.dumps(entry, separators=(",", ":"), sort_keys=True).encode("utf-8")
            digest = sha256_hex(entry_bytes)
            if digest != rec["hash"]:
                print(f"[FAIL] seq {i}: hash mismatch")
                ok = False
            prev = rec["hash"]
    print("OK" if ok else "FAILED")

if __name__ == "__main__":
    main()
'@ },
  @{ Path = "scripts/submit_ots.py"; Content = @'
#!/usr/bin/env python3
"""Create an OpenTimestamps (.ots) request from the current tip hash.
This script writes a payload you can later submit with the OpenTimestamps client.
"""
import json, subprocess, shutil, sys
from pathlib import Path

STATE_FILE = Path("shared/audit-data/chain/state.json")
OUT_DIR = Path("shared/audit-data/anchors")
OUT_DIR.mkdir(parents=True, exist_ok=True)

def main():
    if not STATE_FILE.exists():
        print("No state file found. Create at least one event first.")
        sys.exit(1)
    tip = json.loads(STATE_FILE.read_text())
    tip_hash = tip["hash"]
    hash_txt = OUT_DIR / f"tip_{tip['seq']}.txt"
    hash_txt.write_text(tip_hash + "\n")

    ots_bin = shutil.which("ots")
    if ots_bin:
        try:
            subprocess.run([ots_bin, "stamp", str(hash_txt)], check=False)
            print("Created OTS request (if network reachable). Files in", OUT_DIR)
        except Exception:
            print("OTS client present but failed to run; kept hash text only.")
    else:
        print("OpenTimestamps client not found (ots). Wrote hash text only.")

if __name__ == "__main__":
    main()
'@ },
  @{ Path = "scripts/submit_chainpoint.py"; Content = @'
#!/usr/bin/env python3
"""Prepare a Chainpoint-ready JSON payload from the current tip hash.
This does not contact Chainpoint; it produces a payload you can POST later.
"""
import json, sys, time
from pathlib import Path

STATE_FILE = Path("shared/audit-data/chain/state.json")
OUT_DIR = Path("shared/audit-data/anchors")
OUT_DIR.mkdir(parents=True, exist_ok=True)

def main():
    if not STATE_FILE.exists():
        print("No state file found. Create at least one event first.")
        sys.exit(1)
    tip = json.loads(STATE_FILE.read_text())
    tip_hash = tip["hash"]
    payload = {
        "hashes": [tip_hash],
        "meta": {"created": int(time.time()), "seq": tip["seq"], "source": "quantasport-audit"}
    }
    out = OUT_DIR / f"chainpoint_payload_seq_{tip['seq']}.json"
    out.write_text(json.dumps(payload, indent=2))
    print("Wrote:", out)

if __name__ == "__main__":
    main()
'@ }
)

# -----------------------------
# Write files
# -----------------------------
foreach ($f in $files) { Write-File -Path $f.Path -Content $f.Content }

# Pre-create persistent folders for volumes
$folders = @(
  "shared/audit-data/inbox",
  "shared/audit-data/chain",
  "shared/audit-data/anchors",
  "shared/audit-data/anchor_requests",
  "content"
)
foreach ($d in $folders) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null; Write-Host "Created $d" }
}

Write-Host "\nAll files written."

if ($Run) {
  Write-Host "\nStarting Docker stack..." -ForegroundColor Cyan
  try {
    docker --version | Out-Null
  } catch {
    Write-Warning "Docker not found on PATH. Start Docker Desktop and run: docker compose up -d --build"
    exit 1
  }
  docker compose up -d --build
  Write-Host "\nDone. Open:"
  Write-Host "- API docs:   http://localhost:8000/docs"
  Write-Host "- Dashboard:  http://localhost:8501"
}
```

---

## How to add & run it (quick)

1. In GitHub: **Add file → Create new file** → name it `bootstrap-quantasport-oss.ps1` (root) → paste the script above → **Commit**.
2. On your PC, open PowerShell in the repo folder and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
./bootstrap-quantasport-oss.ps1 -Run
```

3. Open:

* API → [http://localhost:8000/docs](http://localhost:8000/docs)
* UI → [http://localhost:8501](http://localhost:8501)

This is **not** the short script; this is the full generator that creates **all** files and folders.
