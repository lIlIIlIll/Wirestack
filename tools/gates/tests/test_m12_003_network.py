"""Behavioral fixture tests. Socket tests run only in an owned network namespace."""
import os
import socket
import struct
import subprocess
import sys
import unittest
from pathlib import Path

from tools.gates.m12_003_network import Fixture, dns_answer


class DnsAnswerTests(unittest.TestCase):
    def test_answer_preserves_transaction_and_question(self):
        question = b'\x05fault\x07example\x04test\x00\x00\x01\x00\x01'
        request = b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00' + question
        answer = dns_answer(request)
        self.assertEqual(answer[:2], b'\x12\x34')
        self.assertEqual(struct.unpack('!6H', answer[:12]), (0x1234, 0x8180, 1, 1, 0, 0))
        self.assertEqual(answer[12:12 + len(question)], question)
        self.assertEqual(answer[-4:], socket.inet_aton('192.0.2.2'))

    def test_invalid_label_and_question_tail_fail_closed(self):
        header = b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00'
        for tail in (b'\xc0\x0c\x00\x01\x00\x01', b'\x01a\x00\x00\x01\x00\x01garbage'):
            with self.subTest(tail=tail), self.assertRaises(ValueError):
                dns_answer(header + tail)


class IsolatedFixtureTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('WIRESTACK_NETWORK_PACKET_TESTS') == '1', 'requires authorized netem-capable environment')
    def test_original_response_recovers_after_real_packet_loss(self):
        script = r'''
import socket, threading
from tools.gates.m12_003_network import Fixture, configure_namespace, command, reset_impairment, tc_stats
configure_namespace()
fixture = Fixture('delay_loss')
try:
    command(['tc', 'qdisc', 'add', 'dev', 'lo', 'root', 'netem', 'delay', '20ms'])
    with socket.create_connection(('192.0.2.2', fixture.port), timeout=3) as peer:
        peer.sendall(bytes([12003 % 251 + 1]))
        assert peer.recv(1) == bytes([12003 % 251 + 1]), 'original payload lost or changed'
        peer.sendall(b'z')
        assert peer.recv(1) == b'z', 'subsequent request did not recover'
    losses = [e['tc'] for e in fixture.observations if e['event'] == 'original_response_dropped']
    assert losses and losses[0]['dropped'] > 0 and 'loss 100%' in losses[0]['raw'], losses
    assert any(e['event'] == 'packet_fault_removed_before_kernel_retransmit' for e in fixture.observations)
    assert 'delay 20ms' in tc_stats('qdisc')['raw']
finally:
    fixture.close()
    reset_impairment()
assert not fixture.errors, fixture.errors
assert not fixture.worker.is_alive() and threading.active_count() == 1
assert all(s.fileno() == -1 for s in fixture.sockets)
print('ORIGINAL_RESPONSE_RETRANSMITTED_PASS')
'''
        root = Path(__file__).resolve().parents[3]
        result = subprocess.run(['unshare', '--user', '--map-root-user', '--net', sys.executable, '-c', script],
                                cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('ORIGINAL_RESPONSE_RETRANSMITTED_PASS', result.stdout)
    def test_native_peer_modes(self):
        script = r'''
import socket, threading
from tools.gates.m12_003_network import Fixture, configure_namespace
configure_namespace()
for mode in ('rst', 'peer_no_write', 'peer_no_read'):
    fixture = Fixture(mode)
    try:
        with socket.create_connection(('192.0.2.2', fixture.port), timeout=1) as peer:
            peer.settimeout(.2)
            peer.sendall(b'x')
            if mode == 'rst':
                try:
                    peer.recv(1)
                    raise AssertionError('RST did not reset real TCP peer')
                except ConnectionResetError:
                    pass
            elif mode == 'peer_no_write':
                try:
                    peer.recv(1)
                    raise AssertionError('silent fixture responded')
                except socket.timeout:
                    pass
            else:
                assert fixture.worker.is_alive()
    finally:
        fixture.close()
    assert not fixture.worker.is_alive()
    assert all(s.fileno() == -1 for s in fixture.sockets)
    assert not fixture.errors, fixture.errors
assert threading.active_count() == 1
print('ISOLATED_FIXTURE_PASS')
'''
        root = Path(__file__).resolve().parents[3]
        result = subprocess.run(['unshare', '--user', '--map-root-user', '--net', sys.executable, '-c', script],
                                cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('ISOLATED_FIXTURE_PASS', result.stdout)


if __name__ == '__main__':
    unittest.main()
