package wirestack.http

import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*

/** Bounded deterministic fuzz smoke for URL and proxy inputs in every normal test run. */
@Test
class Http1DeterministicFuzzTest {
    @TestCase
    func acceptedUrlMutationsRoundTripToOneCanonicalIdentity(): Unit {
        let seeds = [
            "https://example.com:8443/a/b?q=1",
            "http://127.0.0.1/path",
            "https://[2001:db8::1]/"
        ]
        let replacements = [9u8, 13u8, 32u8, 35u8, 37u8, 47u8, 58u8, 64u8, 91u8, 92u8, 127u8]
        var accepted: Int64 = 0
        var rejected: Int64 = 0
        for (seed in seeds) {
            let bytes = seed.toArray()
            for (index in 0..bytes.size) {
                for (replacement in replacements) {
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
    }

    @TestCase
    func acceptedNoProxyMutationsRemainDeterministicAcrossTargets(): Unit {
        let seeds = ["example.com:8080", "*.internal.test", "[2001:db8::1]:443"]
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
