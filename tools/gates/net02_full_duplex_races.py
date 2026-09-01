#!/usr/bin/env python3
"""Capture Linux x86_64 GATE-NET-02 evidence from the active Cangjie SDK."""
from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest

import argparse, datetime as dt, json, math, os, platform, re, shutil
import signal, socket, subprocess, sys, threading, time
from pathlib import Path
from typing import Any, Sequence

SCHEMA_VERSION=1
RESULT_RE=re.compile(r"^RESULT\s+(.+)$",re.M)
FIELD_RE=re.compile(r"([A-Za-z][A-Za-z0-9]*)=([^\s]+)")

SOURCES={
"full-duplex":r'''import std.net.*
import std.sync.*
import std.convert.*
main(args:Array<String>):Int64 {
 let s=TcpSocket("127.0.0.1",UInt16.parse(args[0]));s.connect();let rb=AtomicInt64(0);let wb=AtomicInt64(0);let rc=AtomicInt64(0);let wc=AtomicInt64(0)
 let r=spawn{let b=Array<Byte>(16384,repeat:0);var total:Int64=0;var ok=true;try{while(total<262144){let n=s.read(b);if(n==0){rc.store(2);break};var i:Int64=0;while(i<n){if(b[i]!=11u8){ok=false};i++};total+=n};if(total==262144&&ok){rc.store(1)}else if(rc.load()==0){rc.store(3)}}catch(_:SocketException){rc.store(4)}catch(_:Exception){rc.store(5)};rb.store(total)}
 let w=spawn{let b=Array<Byte>(16384,repeat:23);var total:Int64=0;try{while(total<262144){s.write(b);total+=b.size};wc.store(1)}catch(_:SocketException){wc.store(2)}catch(_:Exception){wc.store(3)};wb.store(total)}
 r.get();w.get();s.close();println("RESULT scenario=full-duplex readBytes=${rb.load()} writeBytes=${wb.load()} readCode=${rc.load()} writeCode=${wc.load()}");0}
''',
"close-race":r'''import std.net.*
import std.sync.*
import std.time.*
import std.convert.*
main(args:Array<String>):Int64 {
 let p=UInt16.parse(args[0]);let delay=Int64.parse(args[1]);let seed=Int64.parse(args[2]);let s=TcpSocket("127.0.0.1",p);s.connect();s.sendBufferSize=4096
 let e=MonoTime.now();let rs=AtomicBool(false);let ws=AtomicBool(false);let re=AtomicInt64(-1);let we=AtomicInt64(-1);let rc=AtomicInt64(0);let wc=AtomicInt64(0);let writes=AtomicInt64(0)
 let r=spawn{rs.store(true);let b=Array<Byte>(4096,repeat:0);try{let n=s.read(b);rc.store(if(n==0){1}else{2})}catch(_:SocketException){rc.store(3)}catch(_:Exception){rc.store(4)};re.store((MonoTime.now()-e).toNanoseconds())}
 let w=spawn{ws.store(true);let b=Array<Byte>(65536,repeat:29);try{while(true){s.write(b);writes.fetchAdd(1)}}catch(_:SocketTimeoutException){wc.store(1)}catch(_:SocketException){wc.store(2)}catch(_:Exception){wc.store(3)};we.store((MonoTime.now()-e).toNanoseconds())}
 while(!rs.load()||!ws.load()){sleep(Duration.millisecond)};sleep(delay*Duration.millisecond);let cs=(MonoTime.now()-e).toNanoseconds();var cc:Int64=0
 try{s.close()}catch(_:SocketException){cc=1}catch(_:Exception){cc=2};let cd=(MonoTime.now()-e).toNanoseconds();r.get();w.get()
 println("RESULT scenario=close-race seed=${seed} delayMs=${delay} closeStartNs=${cs} closeDoneNs=${cd} readEndNs=${re.load()} writeEndNs=${we.load()} readCode=${rc.load()} writeCode=${wc.load()} closeCode=${cc} writes=${writes.load()}");0}
''',
"same-read":r'''import std.net.*
import std.sync.*
import std.convert.*
main(args:Array<String>):Int64 {
 let s=TcpSocket("127.0.0.1",UInt16.parse(args[0]));s.connect();let ready=AtomicInt64(0);let go=AtomicBool(false);let c1=AtomicInt64(0);let c2=AtomicInt64(0);let n1=AtomicInt64(0);let n2=AtomicInt64(0)
 let r1=spawn{ready.fetchAdd(1);while(!go.load()){};let b=Array<Byte>(4096,repeat:0);try{let n=s.read(b);var ok=true;var i:Int64=0;while(i<n){if(b[i]!=37u8){ok=false};i++};n1.store(n);c1.store(if(ok){1}else{2})}catch(_:SocketException){c1.store(3)}catch(_:Exception){c1.store(4)}}
 let r2=spawn{ready.fetchAdd(1);while(!go.load()){};let b=Array<Byte>(4096,repeat:0);try{let n=s.read(b);var ok=true;var i:Int64=0;while(i<n){if(b[i]!=37u8){ok=false};i++};n2.store(n);c2.store(if(ok){1}else{2})}catch(_:SocketException){c2.store(3)}catch(_:Exception){c2.store(4)}}
 while(ready.load()<2){};go.store(true);r1.get();r2.get();s.close();println("RESULT scenario=same-read code1=${c1.load()} code2=${c2.load()} bytes1=${n1.load()} bytes2=${n2.load()}");0}
''',
"same-write":r'''import std.net.*
import std.sync.*
import std.convert.*
main(args:Array<String>):Int64 {
 let s=TcpSocket("127.0.0.1",UInt16.parse(args[0]));s.connect();let ready=AtomicInt64(0);let go=AtomicBool(false);let c1=AtomicInt64(0);let c2=AtomicInt64(0)
 let w1=spawn{ready.fetchAdd(1);while(!go.load()){};let b=Array<Byte>(65536,repeat:41);try{s.write(b);c1.store(1)}catch(_:SocketException){c1.store(2)}catch(_:Exception){c1.store(3)}}
 let w2=spawn{ready.fetchAdd(1);while(!go.load()){};let b=Array<Byte>(65536,repeat:53);try{s.write(b);c2.store(1)}catch(_:SocketException){c2.store(2)}catch(_:Exception){c2.store(3)}}
 while(ready.load()<2){};go.store(true);w1.get();w2.get();s.close();println("RESULT scenario=same-write code1=${c1.load()} code2=${c2.load()}");0}
''',
"abort-probe":r'''import std.net.*
main():Int64 {let s=TcpSocket("127.0.0.1",1u16);s.abort();0}
'''}

class GateError(RuntimeError):pass

def process(command:Sequence[str],cwd:Path,timeout:float)->dict[str,Any]:
 kw={"args":list(command),"cwd":cwd,"stdin":subprocess.DEVNULL,"stdout":subprocess.PIPE,"stderr":subprocess.PIPE,"text":True,"errors":"replace","shell":False}
 if os.name=="nt":kw["creationflags"]=getattr(subprocess,"CREATE_NEW_PROCESS_GROUP",0)
 else:kw["start_new_session"]=True
 p=subprocess.Popen(**kw);started=time.monotonic();timed=False
 try:out,err=p.communicate(timeout=timeout)
 except subprocess.TimeoutExpired:
  timed=True
  if os.name=="nt":p.kill()
  else:
   try:os.killpg(p.pid,signal.SIGKILL)
   except ProcessLookupError:pass
  out,err=p.communicate()
 return {"exit":p.returncode,"timed_out":timed,"duration_ms":round((time.monotonic()-started)*1000,3),"stdout":out[-65536:],"stderr":err[-65536:]}

def parse(stdout:str)->dict[str,str]:
 found=RESULT_RE.findall(stdout)
 if len(found)!=1:raise GateError(f"expected one RESULT line, found {len(found)}")
 return dict(FIELD_RE.findall(found[0]))

def pct(values:Sequence[float],p:float)->float|None:
 if not values:return None
 ordered=sorted(values);return round(ordered[max(1,math.ceil(p/100*len(ordered)))-1],3)

class Server:
 def __init__(self,mode:str,timeout:float=5.0):
  self.mode=mode;self.timeout=timeout;self.port=0;self.ready=threading.Event();self.stop=threading.Event();self.error=None;self.data=bytearray();self.thread=threading.Thread(target=self._run,daemon=True)
 def start(self)->None:
  self.thread.start()
  if not self.ready.wait(2):raise GateError("server did not become ready")
 def close(self)->None:
  self.stop.set();self.thread.join(2)
  if self.thread.is_alive():raise GateError("server thread leaked")
  if self.error:raise GateError(self.error)
 def _run(self)->None:
  try:
   with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    if self.mode=="passive":listener.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4096)
    listener.bind(("127.0.0.1",0));listener.listen(1);listener.settimeout(.2);self.port=int(listener.getsockname()[1]);self.ready.set();deadline=time.monotonic()+self.timeout
    while not self.stop.is_set():
     if time.monotonic()>deadline:raise GateError("server accept timeout")
     try:conn,_=listener.accept();break
     except socket.timeout:continue
    else:return
    with conn:
     conn.settimeout(.2)
     if self.mode=="full":
      sender=threading.Thread(target=lambda:conn.sendall(bytes([11])*262144),daemon=True);sender.start()
      while len(self.data)<262144:
       chunk=conn.recv(min(65536,262144-len(self.data)))
       if not chunk:break
       self.data.extend(chunk)
      sender.join(2)
     elif self.mode=="same-read":
      time.sleep(.05);conn.sendall(bytes([37])*8192)
      while not self.stop.wait(.02):
       try:
        if not conn.recv(4096):break
       except socket.timeout:continue
       except OSError:break
     elif self.mode=="same-write":
      while not self.stop.is_set():
       try:chunk=conn.recv(65536)
       except socket.timeout:continue
       if not chunk:break
       self.data.extend(chunk)
     else:
      while not self.stop.wait(.02):pass
  except Exception as e:
   if not self.stop.is_set():self.error=f"{type(e).__name__}: {e}"
   self.ready.set()

def run_with_server(binary:Path,args:list[str],mode:str,timeout:float)->tuple[dict[str,Any],Server]:
 server=Server(mode,timeout);server.start();result=process([str(binary),str(server.port),*args],binary.parent,timeout);server.close();return result,server

def compile_all(root:Path,timeout:float)->tuple[dict[str,Path],dict[str,Any]]:
 binaries={};metadata={}
 for name,source in SOURCES.items():
  directory=root/name;directory.mkdir(parents=True,exist_ok=True);src=directory/f"{name}.cj";src.write_text(source);binary=directory/name
  result=process(["cjc",str(src),"-o",str(binary)],directory,timeout);metadata[name]={"source_sha256":evidence_digest.text_evidence_bytes_sha256(source.encode()),"compile":result}
  if name=="abort-probe":continue
  if result["timed_out"] or result["exit"]!=0 or not binary.is_file():raise GateError(f"compile failed for {name}: {result}")
  binaries[name]=binary
 return binaries,metadata

def full_sample(binary:Path,timeout:float)->dict[str,Any]:
 result,server=run_with_server(binary,[],"full",timeout);value=parse(result["stdout"]);ok=not result["timed_out"] and result["exit"]==0 and int(value.get("readBytes","-1"))==262144 and int(value.get("writeBytes","-1"))==262144 and value.get("readCode")=="1" and value.get("writeCode")=="1" and len(server.data)==262144 and all(x==23 for x in server.data)
 return {"decision":"PASS" if ok else "FAIL","fields":value,"server_received":len(server.data),"server_payload_ok":all(x==23 for x in server.data),"process":result}

def close_sample(binary:Path,seed:int,timeout:float)->dict[str,Any]:
 delay=[1,2,5,10,20,50,100][seed%7];result,server=run_with_server(binary,[str(delay),str(seed)],"passive",timeout);value=parse(result["stdout"]);cs=int(value.get("closeStartNs","-1"));re=int(value.get("readEndNs","-1"));we=int(value.get("writeEndNs","-1"));ok=not result["timed_out"] and result["exit"]==0 and value.get("readCode")=="3" and value.get("writeCode")=="2" and value.get("closeCode")=="0" and re>=cs and we>=cs
 return {"decision":"PASS" if ok else "FAIL","seed":seed,"delay_ms":delay,"read_wake_ms":round((re-cs)/1e6,3) if re>=cs else None,"write_wake_ms":round((we-cs)/1e6,3) if we>=cs else None,"fields":value,"process":result}

def same_read_sample(binary:Path,timeout:float)->dict[str,Any]:
 result,server=run_with_server(binary,[],"same-read",timeout);v=parse(result["stdout"]);codes=[int(v.get("code1","0")),int(v.get("code2","0"))];counts=[int(v.get("bytes1","-1")),int(v.get("bytes2","-1"))];success=[i for i,c in enumerate(codes) if c==1];valid=not result["timed_out"] and result["exit"]==0 and len(success)>=1 and all(counts[i]==4096 for i in success) and all(c in {1,3,4} for c in codes)
 return {"decision":"OBSERVED" if valid else "FAIL","outcome":f"codes={codes},bytes={counts}","fields":v,"process":result}

def same_write_sample(binary:Path,timeout:float)->dict[str,Any]:
 result,server=run_with_server(binary,[],"same-write",timeout);v=parse(result["stdout"]);codes=[int(v.get("code1","0")),int(v.get("code2","0"))];c41=server.data.count(41);c53=server.data.count(53);other=len(server.data)-c41-c53;expected=(65536 if codes[0]==1 else 0)+(65536 if codes[1]==1 else 0);valid=not result["timed_out"] and result["exit"]==0 and all(c in {1,2,3} for c in codes) and len(server.data)==expected and c41==(65536 if codes[0]==1 else 0) and c53==(65536 if codes[1]==1 else 0) and other==0
 return {"decision":"OBSERVED" if valid else "FAIL","outcome":f"codes={codes},bytes={len(server.data)},41={c41},53={c53}","fields":v,"server":{"bytes":len(server.data),"pattern41":c41,"pattern53":c53,"other":other},"process":result}

def version(command:Sequence[str])->str|None:
 try:return subprocess.run(command,capture_output=True,text=True,timeout=10).stdout.strip()[:4096]
 except Exception:return None

def execute(root:Path,repetitions:int,races:int,timeout:float,revision:str)->dict[str,Any]:
 if not shutil.which("cjc"):raise GateError("cjc unavailable; source the supplied SDK")
 binaries,compile_meta=compile_all(root,timeout)
 full=[full_sample(binaries["full-duplex"],timeout) for _ in range(repetitions)]
 close=[close_sample(binaries["close-race"],seed,timeout) for seed in range(races)]
 same_read=[same_read_sample(binaries["same-read"],timeout) for _ in range(repetitions)]
 same_write=[same_write_sample(binaries["same-write"],timeout) for _ in range(repetitions)]
 abort=compile_meta["abort-probe"]["compile"];abort_decision="SUPPORTED" if abort["exit"]==0 and not abort["timed_out"] else "BLOCKED"
 rw=[x["read_wake_ms"] for x in close if x["read_wake_ms"] is not None];ww=[x["write_wake_ms"] for x in close if x["write_wake_ms"] is not None]
 behavior={}
 for name,samples in (("same-read",same_read),("same-write",same_write)):
  for sample in samples:behavior[sample["outcome"]]=behavior.get(sample["outcome"],0)+1
  if name=="same-read":read_outcomes=dict(behavior);behavior={}
  else:write_outcomes=dict(behavior)
 functional=all(x["decision"]=="PASS" for x in full+close);captured=all(x["decision"]!="FAIL" for x in same_read+same_write)
 return {"schema_version":SCHEMA_VERSION,"task_id":"M0-007","gate_id":"GATE-NET-02","task_status":"COMPLETE" if functional and captured else "INCOMPLETE","linux_gate_status":"INCOMPLETE" if abort_decision=="BLOCKED" else ("PASS" if functional and captured else "FAIL"),"global_gate_status":"INCOMPLETE","scope":"Linux x86_64 supplied-SDK std.net full-duplex and concurrency evidence","environment":{"repository_revision":revision,"generated_at_utc":dt.datetime.now(dt.timezone.utc).isoformat(),"os":platform.platform(),"architecture":platform.machine(),"cjc":version(["cjc","--version"]),"cjpm":version(["cjpm","--version"]),"cangjie_home":os.environ.get("CANGJIE_HOME")},"configuration":{"functional_repetitions":repetitions,"close_race_seeds":races,"timeout_seconds":timeout},"compile":compile_meta,"full_duplex":{"decision":"PASS" if all(x["decision"]=="PASS" for x in full) else "FAIL","samples":full},"close_race":{"decision":"PASS" if all(x["decision"]=="PASS" for x in close) else "FAIL","read_wake_ms":{"p50":pct(rw,50),"p95":pct(rw,95),"p99":pct(rw,99),"max":max(rw) if rw else None},"write_wake_ms":{"p50":pct(ww,50),"p95":pct(ww,95),"p99":pct(ww,99),"max":max(ww) if ww else None},"samples":close},"same_direction_read":{"decision":"OBSERVED" if all(x["decision"]=="OBSERVED" for x in same_read) else "FAIL","outcomes":read_outcomes,"samples":same_read},"same_direction_write":{"decision":"OBSERVED" if all(x["decision"]=="OBSERVED" for x in same_write) else "FAIL","outcomes":write_outcomes,"samples":same_write},"abort_capability":{"decision":abort_decision,"compile_exit":abort["exit"],"timed_out":abort["timed_out"],"stderr_sha256":evidence_digest.text_evidence_bytes_sha256(abort["stderr"].encode()),"stderr_excerpt":abort["stderr"][:4096]},"non_claims":["not six-platform GATE-NET-02 completion","same-direction outcomes are observations, not Wirestack contract","no private abort or socket handle used"]}

def main(argv:Sequence[str]|None=None)->int:
 root=Path(__file__).resolve().parents[2];p=argparse.ArgumentParser();p.add_argument("--artifact-dir",type=Path,default=root/"build/gates/net02-full-duplex-races");p.add_argument("--output",type=Path,default=root/"build/gates/net02-full-duplex-races.json");p.add_argument("--repetitions",type=int,default=20);p.add_argument("--race-seeds",type=int,default=100);p.add_argument("--timeout-seconds",type=float,default=8);p.add_argument("--repository-revision",default=os.environ.get("WIRESTACK_REPOSITORY_REVISION","unknown"));p.add_argument("--quick",action="store_true");a=p.parse_args(argv)
 if a.quick:a.repetitions=2;a.race_seeds=5
 try:report=execute(a.artifact_dir.resolve(),a.repetitions,a.race_seeds,a.timeout_seconds,a.repository_revision)
 except Exception as e:print(f"GATE-NET-02 ERROR: {type(e).__name__}: {e}",file=sys.stderr);return 1
 a.output.parent.mkdir(parents=True,exist_ok=True);tmp=a.output.with_suffix(a.output.suffix+".tmp");tmp.write_text(json.dumps(report,indent=2,sort_keys=True)+"\n");os.replace(tmp,a.output)
 print(f"M0-007 task={report['task_status']} linux_gate={report['linux_gate_status']} global={report['global_gate_status']}")
 print(f"full-duplex={report['full_duplex']['decision']} close-race={report['close_race']['decision']} abort={report['abort_capability']['decision']}")
 return 0 if report["task_status"]=="COMPLETE" else 1
if __name__=="__main__":raise SystemExit(main())
