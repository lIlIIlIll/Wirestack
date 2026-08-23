from __future__ import annotations
import sys, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/gates"))
import net04_terminal_evidence as gate

class Tests(unittest.TestCase):
    def proc(self):
        return {"command":["p"],"exit_code":0,"timed_out":False,"duration_ms":1.0,"stdout":"","stderr":""}
    def test_parse_exactly_one(self):
        with self.assertRaises(gate.GateError): gate.parse_result("x")
        with self.assertRaises(gate.GateError): gate.parse_result("RESULT scenario=x terminalCode=1\nRESULT scenario=x terminalCode=1")
    def test_fin(self):
        self.assertEqual("PASS", gate.classify_peer("peer-fin",{"terminalCode":"1","bytes":"0"},self.proc())["decision"])
    def test_rst(self):
        self.assertEqual("PASS", gate.classify_peer("peer-rst",{"terminalCode":"4","bytes":"-1"},self.proc())["decision"])
    def test_local_eof_ambiguous(self):
        f={"terminalCode":"1","terminalBeforeClose":"false","closeStartNs":"1","terminalNs":"2","closeCode":"0"}
        self.assertEqual("AMBIGUOUS",gate.classify_local(f,self.proc())["decision"])
    def test_local_exception_distinct(self):
        f={"terminalCode":"4","terminalBeforeClose":"false","closeStartNs":"1","terminalNs":"2","closeCode":"0"}
        self.assertEqual("PASS",gate.classify_local(f,self.proc())["decision"])
    def test_ordered_races(self):
        peer={"terminalCode":"1","terminalBeforeLocalClose":"true","closeStartNs":"2","terminalNs":"1","seed":"0"}
        local={"terminalCode":"4","terminalBeforeLocalClose":"false","closeStartNs":"1","terminalNs":"2","seed":"1"}
        self.assertEqual("PASS",gate.classify_race("peer-first",peer,self.proc())["decision"])
        self.assertEqual("PASS",gate.classify_race("local-first",local,self.proc())["decision"])
    def test_local_first_eof_ambiguous(self):
        f={"terminalCode":"1","terminalBeforeLocalClose":"false","closeStartNs":"1","terminalNs":"2","seed":"1"}
        self.assertEqual("AMBIGUOUS",gate.classify_race("local-first",f,self.proc())["decision"])
    def test_schedule_covers_orders(self):
        self.assertEqual({"peer-first","local-first","simultaneous"},{gate.race_delays(i)[0] for i in range(6)})

if __name__ == "__main__": unittest.main()
