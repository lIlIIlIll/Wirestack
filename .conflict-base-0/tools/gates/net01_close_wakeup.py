#!/usr/bin/env python3
"""Run the Linux x86_64 part of GATE-NET-01 against the active Cangjie SDK."""
from __future__ import annotations

import argparse, contextlib, datetime as dt, hashlib, json, math, os, platform
import re, shutil, signal, socket, subprocess, sys, tempfile, threading, time
from pathlib import Path
from typing import Any, Iterator, Sequence

SCHEMA_VERSION = 1
THRESHOLD_MS = 50.0
RESULT_RE = re.compile(r"^RESULT\s+(.+)$", re.M)
FIELD_RE = re.compile(r"([A-Za-z][A-Za-z0-9]*)=([^\s]+)")

SOURCES = {
"blocked-read": r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*
main(args: Array<String>): Int64 {
 let s=TcpSocket("127.0.0.1",UInt16.parse(args[0])); s.connect()
 let e=MonoTime.now(); let started=AtomicInt64(-1); let ended=AtomicInt64(-1); let code=AtomicInt64(0)
 let f=spawn { started.store((MonoTime.now()-e).toNanoseconds()); let b=Array<Byte>(1024,repeat:0)
  try { let n=s.read(b); code.store(if(n==0){1}else{2}) } catch(_: SocketException){code.store(3)} catch(_: Exception){code.store(4)}
  ended.store((MonoTime.now()-e).toNanoseconds()) }
 while(started.load()<0){sleep(Duration.millisecond)}; sleep(100*Duration.millisecond)
 let before=ended.load()>=0; let cs=(MonoTime.now()-e).toNanoseconds(); var cc:Int64=0
 try{s.close()}catch(_:SocketException){cc=1}catch(_:Exception){cc=2}; let cd=(MonoTime.now()-e).toNanoseconds(); f.get()
 println("RESULT scenario=blocked-read opStartNs=${started.load()} terminalBeforeClose=${before} closeStartNs=${cs} closeDoneNs=${cd} terminalNs=${ended.load()} terminalCode=${code.load()} closeCode=${cc}"); 0 }
''',
"blocked-write": r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*
main(args: Array<String>): Int64 {
 let s=TcpSocket("127.0.0.1",UInt16.parse(args[0])); s.connect(); s.sendBufferSize=4096
 let e=MonoTime.now(); let started=AtomicInt64(-1); let ended=AtomicInt64(-1); let code=AtomicInt64(0); let count=AtomicInt64(0)
 let f=spawn { started.store((MonoTime.now()-e).toNanoseconds()); let b=Array<Byte>(65536,repeat:7)
  try { while(true){s.write(b);count.fetchAdd(1)} } catch(_:SocketTimeoutException){code.store(1)} catch(_:SocketException){code.store(2)} catch(_:Exception){code.store(3)}
  ended.store((MonoTime.now()-e).toNanoseconds()) }
 while(started.load()<0){sleep(Duration.millisecond)}; sleep(100*Duration.millisecond); let a=count.load(); sleep(100*Duration.millisecond); let b=count.load()
 let before=ended.load()>=0; let cs=(MonoTime.now()-e).toNanoseconds(); var cc:Int64=0
 try{s.close()}catch(_:SocketException){cc=1}catch(_:Exception){cc=2}; let cd=(MonoTime.now()-e).toNanoseconds(); f.get()
 println("RESULT scenario=blocked-write opStartNs=${started.load()} terminalBeforeClose=${before} countA=${a} countB=${b} closeStartNs=${cs} closeDoneNs=${cd} terminalNs=${ended.load()} terminalCode=${code.load()} closeCode=${cc}"); 0 }
''',
"blocked-connect": r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*
main(args: Array<String>): Int64 {
 let s=TcpSocket("127.0.0.1",UInt16.parse(args[0])); let e=MonoTime.now(); let started=AtomicInt64(-1); let ended=AtomicInt64(-1); let code=AtomicInt64(0)
 let f=spawn { started.store((MonoTime.now()-e).toNanoseconds()); try{s.connect();code.store(1)}catch(_:SocketTimeoutException){code.store(2)}catch(_:SocketException){code.store(3)}catch(_:Exception){code.store(4)}; ended.store((MonoTime.now()-e).toNanoseconds()) }
 while(started.load()<0){sleep(Duration.millisecond)}; sleep(100*Duration.millisecond); let before=ended.load()>=0; let cs=(MonoTime.now()-e).toNanoseconds(); var cc:Int64=0
 try{s.close()}catch(_:SocketException){cc=1}catch(_:Exception){cc=2}; let cd=(MonoTime.now()-e).toNanoseconds(); f.get()
 println("RESULT scenario=blocked-connect opStartNs=${started.load()} terminalBeforeClose=${before} closeStartNs=${cs} closeDoneNs=${cd} terminalNs=${ended.load()} terminalCode=${code.load()} closeCode=${cc}"); 0 }
''',
"blocked-accept": r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*
main(args: Array<String>): Int64 {
 let s=TcpServerSocket(bindAt:UInt16.parse(args[0])); s.bind(); let e=MonoTime.now(); let started=AtomicInt64(-1); let ended=AtomicInt64(-1); let code=AtomicInt64(0)
 let f=spawn { started.store((MonoTime.now()-e).toNanoseconds()); try{let c=s.accept();code.store(1);c.close()}catch(_:SocketException){code.store(2)}catch(_:Exception){code.store(3)}; ended.store((MonoTime.now()-e).toNanoseconds()) }
 while(started.load()<0){sleep(Duration.millisecond)}; sleep(100*Duration.millisecond); let before=ended.load()>=0; let cs=(MonoTime.now()-e).toNanoseconds(); var cc:Int64=0
 try{s.close()}catch(_:SocketException){cc=1}catch(_:Exception){cc=2}; let cd=(MonoTime.now()-e).toNanoseconds(); f.get()
 println("RESULT scenario=blocked-accept opStartNs=${started.load()} terminalBeforeClose=${before} closeStartNs=${cs} closeDoneNs=${cd} terminalNs=${ended.load()} terminalCode=${code.load()} closeCode=${cc}"); 0 }
'''}
EXPECTED = {"blocked-read":3,"blocked-write":2,"blocked-connect":3,"blocked-accept":2}

class GateError(RuntimeError): pass

def proc(command: Sequence[str], cwd: Path, timeout: float) -> dict[str, Any]:
    kw={"args":list(command),"cwd":cwd,"stdin":subprocess.DEVNULL,"stdout":subprocess.PIPE,"stderr":subprocess.PIPE,"text":True,"errors":"replace","shell":False}
    if os.name=="nt": kw["creationflags"]=getattr(subprocess,"CREATE_NEW_PROCESS_GROUP",0)
    else: kw["start_new_session"]=True
    p=subprocess.Popen(**kw); start=time.monotonic(); timed=False
    try: out,err=p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed=True
        if os.name=="nt": p.kill()
        else:
            try: os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError: pass
        out,err=p.communicate()
    return {"exit":p.returncode,"timed_out":timed,"duration_ms":round((time.monotonic()-start)*1000,3),"stdout":out[-65536:],"stderr":err[-65536:]}

def fields(stdout: str) -> dict[str,str]:
    found=RESULT_RE.findall(stdout)
    if len(found)!=1: raise GateError(f"expected one RESULT line, found {len(found)}")
    value=dict(FIELD_RE.findall(found[0])); required={"scenario","opStartNs","terminalBeforeClose","closeStartNs","closeDoneNs","terminalNs","terminalCode","closeCode"}
    if required-value.keys(): raise GateError(f"missing fields: {sorted(required-value.keys())}")
    return value

def classify(value: dict[str,str], result: dict[str,Any]) -> dict[str,Any]:
    scenario=value["scenario"]; before=value["terminalBeforeClose"]=="true"
    start=int(value["opStartNs"]); cs=int(value["closeStartNs"]); cd=int(value["closeDoneNs"]); end=int(value["terminalNs"])
    terminal=int(value["terminalCode"]); close=int(value["closeCode"]); a=int(value.get("countA","0")); b=int(value.get("countB","0"))
    blocked=not before and (scenario!="blocked-write" or a==b); wake=round((end-cs)/1e6,3) if end>=cs else None
    ok=(not result["timed_out"] and result["exit"]==0 and blocked and 0<=start<cs<=cd<=end+50_000_000 and end>=cs and close==0 and terminal==EXPECTED.get(scenario) and wake is not None and wake<=THRESHOLD_MS)
    return {"scenario":scenario,"decision":"PASS" if ok else ("NOT_BLOCKED" if not blocked else "FAIL"),"blocked":blocked,"wake_ms":wake,"close_ms":round((cd-cs)/1e6,3),"terminal_code":terminal,"close_code":close,"count_a":a if scenario=="blocked-write" else None,"count_b":b if scenario=="blocked-write" else None,"process":result}

def pct(values: Sequence[float], p: float) -> float|None:
    if not values:return None
    ordered=sorted(values); return round(ordered[max(1,math.ceil(p/100*len(ordered)))-1],3)

@contextlib.contextmanager
def passive(receive_buffer: int|None=None) -> Iterator[int]:
    listener=socket.socket(); listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    if receive_buffer: listener.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,receive_buffer)
    listener.bind(("127.0.0.1",0)); listener.listen(1); port=listener.getsockname()[1]; stop=threading.Event(); accepted=[]
    def run() -> None:
        listener.settimeout(.2)
        while not stop.is_set():
            try: c,_=listener.accept(); accepted.append(c); break
            except socket.timeout: continue
        while not stop.wait(.05): pass
    t=threading.Thread(target=run,daemon=True);t.start()
    try: yield int(port)
    finally:
        stop.set()
        for c in accepted:
            try:c.close()
            except OSError:pass
        listener.close();t.join(2)
        if t.is_alive():raise GateError("server thread leaked")

@contextlib.contextmanager
def saturated() -> Iterator[int]:
    listener=socket.socket();listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);listener.bind(("127.0.0.1",0));listener.listen(1);port=listener.getsockname()[1];fill=[];blocked=False
    for _ in range(32):
        c=socket.socket();c.settimeout(.05)
        try:c.connect(("127.0.0.1",port));fill.append(c)
        except (socket.timeout,TimeoutError):c.close();blocked=True;break
        except OSError:c.close();break
    if not blocked: listener.close(); raise GateError("could not saturate local listen backlog")
    try:yield int(port)
    finally:
        for c in fill:c.close()
        listener.close()

def reserve_port() -> int:
    with socket.socket() as s:s.bind(("127.0.0.1",0));return int(s.getsockname()[1])

def version(command: Sequence[str]) -> str|None:
    try:return subprocess.run(command,capture_output=True,text=True,timeout=10).stdout.strip()[:4096]
    except Exception:return None

def run(repo: Path, artifacts: Path, warmup: int, repetitions: int, timeout: float, revision: str) -> dict[str,Any]:
    if not shutil.which("cjc"):raise GateError("cjc unavailable; source the supplied SDK")
    artifacts.mkdir(parents=True,exist_ok=True); binaries={}; digests={}
    for name,source in SOURCES.items():
        d=artifacts/name;d.mkdir(parents=True,exist_ok=True);src=d/f"{name}.cj";binary=d/name;src.write_text(source);r=proc(["cjc",str(src),"-o",str(binary)],d,timeout)
        if r["timed_out"] or r["exit"]!=0 or not binary.is_file():raise GateError(f"compile failed for {name}: {r}")
        binaries[name]=binary;digests[name]=hashlib.sha256(source.encode()).hexdigest()
    def sample(name: str) -> dict[str,Any]:
        if name=="blocked-connect": cm=saturated()
        elif name=="blocked-accept": cm=contextlib.nullcontext(reserve_port())
        else: cm=passive(4096 if name=="blocked-write" else None)
        with cm as port:
            result=proc([str(binaries[name]),str(port)],artifacts/name,timeout)
        return classify(fields(result["stdout"]),result)
    scenarios=[]
    for name in SOURCES:
        for _ in range(warmup):sample(name)
        samples=[sample(name) for _ in range(repetitions)]; wakes=[x["wake_ms"] for x in samples if x["wake_ms"] is not None]
        decision="PASS" if all(x["decision"]=="PASS" for x in samples) else ("BLOCKED" if all(x["decision"]=="NOT_BLOCKED" for x in samples) else "FAIL")
        scenarios.append({"id":name,"decision":decision,"source_sha256":digests[name],"sample_count":len(samples),"wake_ms":{"p50":pct(wakes,50),"p95":pct(wakes,95),"p99":pct(wakes,99),"max":max(wakes) if wakes else None},"samples":samples})
    return {"schema_version":SCHEMA_VERSION,"task_id":"M0-006","gate_id":"GATE-NET-01","status":"PASS" if all(x["decision"]=="PASS" for x in scenarios) else "FAIL","global_gate_status":"INCOMPLETE","scope":"Linux x86_64 supplied-SDK std.net close/wakeup evidence","non_claims":["not six-platform gate completion","not Wirestack Transport behavior","does not itself unlock UP-*"],"thresholds":{"wake_p99_ms":THRESHOLD_MS},"configuration":{"warmup":warmup,"repetitions":repetitions,"timeout_seconds":timeout},"environment":{"repository_revision":revision,"generated_at_utc":dt.datetime.now(dt.timezone.utc).isoformat(),"os":platform.platform(),"architecture":platform.machine(),"cjc":version(["cjc","--version"]),"cjpm":version(["cjpm","--version"]),"cangjie_home":os.environ.get("CANGJIE_HOME")},"scenarios":scenarios}

def main(argv: Sequence[str]|None=None) -> int:
    root=Path(__file__).resolve().parents[2];p=argparse.ArgumentParser();p.add_argument("--repo-root",type=Path,default=root);p.add_argument("--artifact-dir",type=Path,default=root/"build/gates/net01-close-wakeup");p.add_argument("--output",type=Path,default=root/"build/gates/net01-close-wakeup.json");p.add_argument("--warmup",type=int,default=2);p.add_argument("--repetitions",type=int,default=20);p.add_argument("--timeout-seconds",type=float,default=8);p.add_argument("--repository-revision",default=os.environ.get("WIRESTACK_REPOSITORY_REVISION","unknown"));p.add_argument("--quick",action="store_true");a=p.parse_args(argv)
    if a.quick:a.warmup=0;a.repetitions=2
    try:report=run(a.repo_root.resolve(),a.artifact_dir.resolve(),a.warmup,a.repetitions,a.timeout_seconds,a.repository_revision)
    except Exception as e:print(f"GATE-NET-01: ERROR: {type(e).__name__}: {e}",file=sys.stderr);return 1
    a.output.parent.mkdir(parents=True,exist_ok=True);tmp=a.output.with_suffix(a.output.suffix+".tmp");tmp.write_text(json.dumps(report,indent=2,sort_keys=True)+"\n");os.replace(tmp,a.output)
    print(f"GATE-NET-01 Linux x86_64: {report['status']} (global: INCOMPLETE)")
    for x in report["scenarios"]:print(f"- {x['id']}: {x['decision']}; samples={x['sample_count']}; wake p99={x['wake_ms']['p99']} ms")
    return 0 if report["status"]=="PASS" else 1
if __name__=="__main__":raise SystemExit(main())
