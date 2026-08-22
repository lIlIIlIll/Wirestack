# M0 execution context

Wirestack M0 development is being executed against the user-supplied Cangjie SDK snapshot:

- `cjc 1.1.0-alpha.20260817040003 (cjnative)`
- target: `x86_64-unknown-linux-gnu`
- `cjpm 1.1.3`

This SDK is an execution input, not a vendored repository dependency. The archive and extracted SDK must not be committed to Wirestack. Every SDK-backed evidence report must record the exact compiler/package-manager versions and target observed by the command that produced it.

Linux/x86_64 evidence from this SDK does not count as Windows, macOS, Android, iOS, HarmonyOS/OpenHarmony, Linux musl, or other native-platform evidence.
