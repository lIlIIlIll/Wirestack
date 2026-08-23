package wirestack.internal.http1

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HttpConnectionPoolKeyTest {
    @TestCase
    func canonicalOriginProducesStableEqualityAndHash(): Unit {
        let first = poolKey()
        let second = HttpConnectionPoolKey(
            "HTTPS", "EXAMPLE.COM", 443,
            None<String>, "default-network", "tls-context", "trust-context",
            "no-client", "aws-lc:fingerprint", "h2,http/1.1"
        )
        @Expect(first, second)
        @Expect(first.hashCode(), second.hashCode())
    }

    @TestCase
    func everySecurityAndRouteDimensionPartitionsReuse(): Unit {
        let baseline = poolKey()
        let variants = [
            HttpConnectionPoolKey("http", "example.com", 443, None<String>, "default-network", "tls-context", "trust-context", "no-client", "aws-lc:fingerprint", "h2,http/1.1"),
            HttpConnectionPoolKey("https", "other.test", 443, None<String>, "default-network", "tls-context", "trust-context", "no-client", "aws-lc:fingerprint", "h2,http/1.1"),
            HttpConnectionPoolKey("https", "example.com", 8443, None<String>, "default-network", "tls-context", "trust-context", "no-client", "aws-lc:fingerprint", "h2,http/1.1"),
            HttpConnectionPoolKey("https", "example.com", 443, Some("proxy-a"), "default-network", "tls-context", "trust-context", "no-client", "aws-lc:fingerprint", "h2,http/1.1"),
            HttpConnectionPoolKey("https", "example.com", 443, None<String>, "network-b", "tls-context", "trust-context", "no-client", "aws-lc:fingerprint", "h2,http/1.1"),
            HttpConnectionPoolKey("https", "example.com", 443, None<String>, "default-network", "tls-b", "trust-context", "no-client", "aws-lc:fingerprint", "h2,http/1.1"),
            HttpConnectionPoolKey("https", "example.com", 443, None<String>, "default-network", "tls-context", "trust-b", "no-client", "aws-lc:fingerprint", "h2,http/1.1"),
            HttpConnectionPoolKey("https", "example.com", 443, None<String>, "default-network", "tls-context", "trust-context", "client-b", "aws-lc:fingerprint", "h2,http/1.1"),
            HttpConnectionPoolKey("https", "example.com", 443, None<String>, "default-network", "tls-context", "trust-context", "no-client", "other-provider", "h2,http/1.1"),
            HttpConnectionPoolKey("https", "example.com", 443, None<String>, "default-network", "tls-context", "trust-context", "no-client", "aws-lc:fingerprint", "http/1.1")
        ]
        for (variant in variants) { @Expect(variant != baseline) }
    }

    @TestCase
    func refusesIncompletePartitionIdentities(): Unit {
        var rejected = false
        try {
            let _ = HttpConnectionPoolKey(
                "https", "example.com", 443, None<String>, "", "tls", "trust", "client", "provider", "h2"
            )
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        @Expect(rejected)
    }
}

private func poolKey(): HttpConnectionPoolKey {
    HttpConnectionPoolKey(
        "https", "example.com", 443,
        None<String>, "default-network", "tls-context", "trust-context",
        "no-client", "aws-lc:fingerprint", "h2,http/1.1"
    )
}
