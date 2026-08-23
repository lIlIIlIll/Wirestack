# Submitted-code verification

The exact code on PR branch `task/M0-010-large-buffer-profile-v2` was downloaded
and verified again with the supplied SDK after the PR was opened.

Executed:

```bash
python3 -m unittest discover -s tools/gates/tests \
  -p 'test_net05_large_buffer_profile.py' -v
python3 -m py_compile \
  tools/gates/net05_large_buffer_profile.py \
  tools/gates/net05_large_buffer_profile_sources.py
python3 tools/architecture_guard.py --root . --format text
python3 tools/gates/net05_large_buffer_profile.py --quick

flock -x /mnt/data/wirestack-linux-native-gate.lock \
  python3 tools/gates/net05_large_buffer_profile.py \
    --warmup 1 --repetitions 5
```

Both the quick and formal runs returned Linux profile `PASS`; both formal cases
passed exact byte and payload-pattern verification, and neither showed a fixed
4 KiB application-visible read cap.
