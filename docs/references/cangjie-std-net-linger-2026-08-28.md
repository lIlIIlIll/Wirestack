# Cangjie std.net linger behavior, 2026-08-28

## Environment

| Item | Value |
|---|---|
| Cangjie compiler | `1.1.0-alpha.20260817040003 (cjnative)` |
| Target | `x86_64-unknown-linux-gnu` |
| Reference runtime source | `846ee90e98e0910d448ee305f1794c832b633924` |

## Public API

The cached `main/std` documentation index generated on 2026-08-27 records
these non-deprecated APIs:

- `TcpSocket.linger: ?Duration`
- `TcpSocket.setSocketOption(Int32, Int32, CPointer<Unit>, UIntNative)`
- `OptionLevel.SOCKET`
- `OptionName.SO_LINGER`

## Observed constraint

The reference `std.net` implementation rounds every `Some(Duration)` linger
value up to at least one second. `Some(Duration.Zero)` therefore does not encode
the native abortive-close value `{ enabled = 1, seconds = 0 }`.

Wirestack does not patch `std.net`. `StdNetTransport.abort` uses the public raw
socket-option method to install the platform `SO_LINGER` value before calling
`TcpSocket.close`. The adapter does not read or cache a native socket handle.

