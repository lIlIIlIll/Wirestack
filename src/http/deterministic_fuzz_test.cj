package wirestack.http

import std.env.getVariable
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*

/** Bounded deterministic fuzz smoke for URL and proxy inputs in every normal test run. */
@Test
class Http1DeterministicFuzzTest {
    @TestCase
    func acceptedUrlMutationsRoundTripToOneCanonicalIdentity(): Unit {
        let seeds = [
            m7023HttpSeed("url-authority", "https://example.com:8443/a/b?q=1"),
            "http://127.0.0.1/path",
            "https://[2001:db8::1]/"
        ]
        let replacements = [9u8, 13u8, 32u8, 35u8, 37u8, 47u8, 58u8, 64u8, 91u8, 92u8, 127u8]
        var accepted: Int64 = 0
        var rejected: Int64 = 0
        var executions: Int64 = 0
        for (seed in seeds) {
            let bytes = seed.toArray()
            for (index in 0..bytes.size) {
                for (replacement in replacements) {
                    executions++
                    let mutated = bytes.clone()
                    mutated[index] = replacement
                    try {
                        let first = HttpUrl.parse(String.fromUtf8(mutated))
                        let second = HttpUrl.parse(first.toString())
                        @Expect(first.scheme, second.scheme)
                        @Expect(first.host, second.host)
                        @Expect(first.port, second.port)
                        @Expect(first.requestTarget, second.requestTarget)
                        @Expect(first.toString(), second.toString())
                        accepted++
                    } catch (_: Exception) {
                        rejected++
                    }
                }
            }
        }
        @Expect(accepted > 20)
        @Expect(rejected > 100)
        println(
            "M7023_FUZZ target=url-authority seed=7023 " +
            "iterations=${executions} decision=PASS"
        )
    }

    @TestCase
    func acceptedNoProxyMutationsRemainDeterministicAcrossTargets(): Unit {
        let seeds = [
            m7023HttpSeed("proxy-parser", "example.com:8080"),
            "*.internal.test", "[2001:db8::1]:443"
        ]
        let replacements = [9u8, 32u8, 35u8, 42u8, 47u8, 58u8, 64u8, 91u8, 93u8, 127u8]
        let targets = [
            HttpUrl.parse("http://example.com:8080/"),
            HttpUrl.parse("https://deep.internal.test/"),
            HttpUrl.parse("https://[2001:db8::1]/")
        ]
        var completed: Int64 = 0
        for (seed in seeds) {
            let bytes = seed.toArray()
            for (index in 0..bytes.size) {
                for (replacement in replacements) {
                    let mutated = bytes.clone()
                    mutated[index] = replacement
                    try {
                        let policy = NoProxyPolicy([String.fromUtf8(mutated)])
                        for (target in targets) {
                            let first = policy.matches(target)
                            @Expect(first, policy.matches(target))
                        }
                    } catch (_: Exception) {}
                    completed++
                }
            }
        }
        @Expect(completed > 300)
        println(
            "M7023_FUZZ target=proxy-parser seed=7023 " +
            "iterations=${completed} decision=PASS"
        )
    }

    @TestCase
    func proxyAuthorizationMutationCannotInjectBeforeDnsOrConnect(): Unit {
        for (value in ["Basic safe\r\nX-Evil: yes", "Basic a\u{000b}b", "Basic a\u{007f}b"]) {
            let resolver = FuzzNeverResolver()
            let client = HttpClient.builder()
                .resolver(resolver)
                .proxy(HttpProxyConfig(
                    HttpProxyEndpoint.hostname("proxy.test", 8080),
                    resolver,
                    authorizationProvider: Some(FuzzAuthorization(value))
                ))
                .build()
            var rejected = false
            try { let _ = client.get("http://origin.test/") }
            catch (_: IllegalArgumentException) { rejected = true }
            finally { client.close() }
            @Expect(rejected)
            @Expect(resolver.calls.load(), 0)
        }
    }
}

private func m7023HttpSeed(target: String, fallback: String): String {
    match (getVariable("WIRESTACK_M7_023_TARGET")) {
        case None => fallback
        case Some(actual) =>
            if (actual != target) {
                throw IllegalStateException("M7-023 target mismatch: ${actual}")
            }
            match (getVariable("WIRESTACK_M7_023_CORPUS_HEX")) {
                case Some(value) => String.fromUtf8(m7023HttpHex(value))
                case None => throw IllegalStateException("missing M7-023 corpus")
            }
    }
}

private func m7023HttpHex(value: String): Array<Byte> {
    let input = value.toArray()
    var digits: Int64 = 0
    for (byte in input) { if (byte > 32u8) { digits++ } }
    if (digits == 0 || digits % 2 != 0) {
        throw IllegalArgumentException("invalid M7-023 hex corpus")
    }
    let output = Array<Byte>(digits / 2, repeat: 0u8)
    var high: ?Byte = None<Byte>
    var index: Int64 = 0
    for (byte in input) {
        if (byte <= 32u8) { continue }
        let nibble = m7023HttpNibble(byte)
        match (high) {
            case None => high = Some(nibble)
            case Some(value) =>
                output[index] = (value << 4) | nibble
                index++
                high = None<Byte>
        }
    }
    output
}

private func m7023HttpNibble(value: Byte): Byte {
    if (value >= b'0' && value <= b'9') { value - b'0' }
    else if (value >= b'a' && value <= b'f') { value - b'a' + 10u8 }
    else if (value >= b'A' && value <= b'F') { value - b'A' + 10u8 }
    else { throw IllegalArgumentException("invalid M7-023 hex digit") }
}

private class FuzzAuthorization <: HttpProxyAuthorizationProvider {
    private let value: String
    init(value: String) { this.value = value }
    public func authorization(proxy: HttpProxyEndpoint, target: HttpUrl,
        context: OperationContext): ?String {
        let _ = proxy
        let _ = target
        let _ = context
        Some(value)
    }
}

private class FuzzNeverResolver <: Resolver {
    let calls = AtomicInt64(0)
    public func resolve(host: HostName, service: ?String, options: ResolveOptions,
        context: OperationContext): ResolveResult {
        let _ = host
        let _ = service
        let _ = options
        let _ = context
        calls.fetchAdd(1)
        throw ResolveException(ResolveErrorCode.NameNotFound, "fuzz resolver must not run")
    }
}
