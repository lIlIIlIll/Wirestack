from __future__ import annotations
import importlib.util, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch

MODULE=Path(__file__).resolve().parents[1]/"net02_full_duplex_races.py"
spec=importlib.util.spec_from_file_location("net02",MODULE);gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)

class FakeServer:
 def __init__(self,data=b""):self.data=bytearray(data)

class Net02Tests(unittest.TestCase):
 def result(self,line):return {"exit":0,"timed_out":False,"duration_ms":1.0,"stdout":line+"\n","stderr":""}
 def test_parse_and_percentile(self):
  self.assertEqual("full-duplex",gate.parse("RESULT scenario=full-duplex readBytes=1")["scenario"])
  with self.assertRaises(gate.GateError):gate.parse("")
  self.assertEqual(5.0,gate.pct([1.,2.,3.,4.,5.],95))
 def test_sources_use_only_public_std_net(self):
  self.assertEqual({"full-duplex","close-race","same-read","same-write","abort-probe"},set(gate.SOURCES))
  for source in gate.SOURCES.values():
   self.assertIn("std.net",source);self.assertNotIn("CJ_MRT_Sock",source);self.assertNotIn("stdx.net",source)
 def test_full_duplex_requires_exact_bytes_and_patterns(self):
  line="RESULT scenario=full-duplex readBytes=262144 writeBytes=262144 readCode=1 writeCode=1"
  with patch.object(gate,"run_with_server",return_value=(self.result(line),FakeServer(bytes([23])*262144))):
   self.assertEqual("PASS",gate.full_sample(Path("probe"),1)["decision"])
  with patch.object(gate,"run_with_server",return_value=(self.result(line),FakeServer(bytes([22])*262144))):
   self.assertEqual("FAIL",gate.full_sample(Path("probe"),1)["decision"])
 def test_close_race_requires_both_waiters_after_close(self):
  good="RESULT scenario=close-race seed=1 delayMs=2 closeStartNs=100 closeDoneNs=110 readEndNs=120 writeEndNs=130 readCode=3 writeCode=2 closeCode=0 writes=0"
  bad=good.replace("writeEndNs=130","writeEndNs=90")
  with patch.object(gate,"run_with_server",return_value=(self.result(good),FakeServer())):
   self.assertEqual("PASS",gate.close_sample(Path("probe"),1,1)["decision"])
  with patch.object(gate,"run_with_server",return_value=(self.result(bad),FakeServer())):
   self.assertEqual("FAIL",gate.close_sample(Path("probe"),1,1)["decision"])
 def test_same_direction_evidence_is_observation_not_contract(self):
  read="RESULT scenario=same-read code1=1 code2=4 bytes1=4096 bytes2=0"
  write="RESULT scenario=same-write code1=1 code2=3"
  with patch.object(gate,"run_with_server",return_value=(self.result(read),FakeServer())):
   self.assertEqual("OBSERVED",gate.same_read_sample(Path("probe"),1)["decision"])
  with patch.object(gate,"run_with_server",return_value=(self.result(write),FakeServer(bytes([41])*65536))):
   self.assertEqual("OBSERVED",gate.same_write_sample(Path("probe"),1)["decision"])
 def test_process_timeout_is_bounded(self):
  with tempfile.TemporaryDirectory() as directory:
   result=gate.process([sys.executable,"-c","import time;time.sleep(2)"],Path(directory),.05)
  self.assertTrue(result["timed_out"])

if __name__=="__main__":unittest.main()
