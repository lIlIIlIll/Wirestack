from __future__ import annotations
import importlib.util, tempfile, unittest
from pathlib import Path

MODULE=Path(__file__).resolve().parents[1]/"net01_close_wakeup.py"
spec=importlib.util.spec_from_file_location("net01",MODULE); gate=importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)

class Net01Tests(unittest.TestCase):
 def result(self,scenario="blocked-read",**change):
  value={"scenario":scenario,"opStartNs":"1","terminalBeforeClose":"false","closeStartNs":"100000000","closeDoneNs":"100100000","terminalNs":"100200000","terminalCode":str(gate.EXPECTED[scenario]),"closeCode":"0"}
  if scenario=="blocked-write":value|={"countA":"0","countB":"0"}
  value.update(change);return value
 def process(self,**change):
  value={"exit":0,"timed_out":False,"duration_ms":110.0,"stdout":"","stderr":""};value.update(change);return value
 def test_parse_exactly_one_result(self):
  parsed=gate.fields("noise\nRESULT scenario=blocked-read opStartNs=1 terminalBeforeClose=false closeStartNs=2 closeDoneNs=3 terminalNs=4 terminalCode=3 closeCode=0\n")
  self.assertEqual("blocked-read",parsed["scenario"])
  with self.assertRaises(gate.GateError):gate.fields("")
 def test_valid_close_terminal_passes(self):
  self.assertEqual("PASS",gate.classify(self.result(),self.process())["decision"])
 def test_operation_must_be_blocked(self):
  self.assertEqual("NOT_BLOCKED",gate.classify(self.result(terminalBeforeClose="true"),self.process())["decision"])
 def test_write_progress_means_not_blocked(self):
  self.assertEqual("NOT_BLOCKED",gate.classify(self.result("blocked-write",countA="1",countB="2"),self.process())["decision"])
 def test_wrong_terminal_and_timeout_fail(self):
  self.assertEqual("FAIL",gate.classify(self.result(terminalCode="1"),self.process())["decision"])
  self.assertEqual("FAIL",gate.classify(self.result(),self.process(timed_out=True,exit=None))["decision"])
 def test_threshold_fails_closed(self):
  self.assertEqual("FAIL",gate.classify(self.result(terminalNs="151000000"),self.process())["decision"])
 def test_nearest_rank_percentile(self):
  self.assertEqual(5.0,gate.pct([1.,2.,3.,4.,5.],95))
 def test_sources_use_public_api_only(self):
  self.assertEqual(set(gate.SOURCES),set(gate.EXPECTED))
  for source in gate.SOURCES.values():
   self.assertIn("std.net",source);self.assertNotIn("CJ_MRT_Sock",source);self.assertNotIn("stdx.net",source)

if __name__=="__main__":unittest.main()
