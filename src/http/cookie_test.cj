package wirestack.http

import std.collection.ArrayList
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HttpCookieJarTest {
    @TestCase
    func cookieSerializesStandardMetadataWithoutInventingBrowserPolicy(): Unit {
        let cookie = Cookie(
            "session",
            "abc_123",
            expires: Some(DateTime.ofUTC(year: 2021, month: 6, dayOfMonth: 9, hour: 10, minute: 18, second: 14)),
            maxAge: Some(60),
            domain: ".Example.COM",
            path: "/account",
            secure: true,
            httpOnly: true
        )
        @Expect(cookie.cookieName, "session")
        @Expect(cookie.cookieValue, "abc_123")
        @Expect(cookie.domain, "example.com")
        @Expect(cookie.toSetCookieString(),
            "session=abc_123; Expires=Wed, 09 Jun 2021 10:18:14 GMT; Max-Age=60; " +
                "Domain=example.com; Path=/account; Secure; HttpOnly")
    }

    @TestCase
    func hostOnlyAndDomainCookiesDoNotLeakAcrossDnsBoundaries(): Unit {
        let jar = CookieJar(rejectPublicSuffixes: ["com", "co.uk"])
        let origin = HttpUrl.parse("https://app.example.com/account/login")
        @Expect(jar.acceptSetCookie("host=one; Path=/", origin))
        @Expect(jar.acceptSetCookie("domain=two; Domain=.example.com; Path=/", origin))

        @Expect(jar.headerFor(HttpUrl.parse("https://app.example.com/")), "host=one; domain=two")
        @Expect(jar.headerFor(HttpUrl.parse("https://deep.app.example.com/")), "domain=two")
        @Expect(jar.headerFor(HttpUrl.parse("https://example.com/")), "domain=two")
        @Expect(jar.cookiesFor(HttpUrl.parse("https://deep.app.example.com/")).size, 1)
        @Expect(jar.headerFor(HttpUrl.parse("https://notexample.com/")), "")
        @Expect(!jar.acceptSetCookie("foreign=x; Domain=evil.test; Path=/", origin))
        @Expect(!jar.acceptSetCookie("suffix=x; Domain=com; Path=/", origin))
        @Expect(jar.snapshot().size, 2)
    }

    @TestCase
    func bundledPublicSuffixRulesProtectRegistrableBoundariesByDefault(): Unit {
        let exactJar = CookieJar()
        let coUkAttacker = HttpUrl.parse("https://attacker.co.uk/")
        @Expect(!exactJar.acceptSetCookie("sid=stolen; Domain=co.uk; Path=/", coUkAttacker))
        @Expect(!exactJar.store(
            Cookie("direct-suffix", "stolen", domain: "co.uk", path: "/"),
            coUkAttacker
        ))
        @Expect(exactJar.acceptSetCookie(
            "sid=valid; Domain=example.co.uk; Path=/",
            HttpUrl.parse("https://app.example.co.uk/")
        ))
        @Expect(exactJar.headerFor(HttpUrl.parse("https://victim.co.uk/")), "")
        @Expect(exactJar.headerFor(HttpUrl.parse("https://api.example.co.uk/")), "sid=valid")

        let wildcardJar = CookieJar()
        @Expect(!wildcardJar.acceptSetCookie(
            "wild=stolen; Domain=foo.ck; Path=/",
            HttpUrl.parse("https://attacker.foo.ck/")
        ))
        @Expect(wildcardJar.acceptSetCookie(
            "exception=valid; Domain=www.ck; Path=/",
            HttpUrl.parse("https://app.www.ck/")
        ))
        @Expect(wildcardJar.headerFor(HttpUrl.parse("https://other.www.ck/")), "exception=valid")

        // A parent scope can cross a wildcard boundary without itself matching a PSL rule.
        let inheritedJar = CookieJar()
        @Expect(!inheritedJar.acceptSetCookie(
            "inherited=stolen; Domain=kawasaki.jp; Path=/",
            HttpUrl.parse("https://attacker.foo.kawasaki.jp/")
        ))
        @Expect(!inheritedJar.store(
            Cookie("inherited", "stolen", domain: "kawasaki.jp", path: "/"),
            HttpUrl.parse("https://app.city.kawasaki.jp/")
        ))
        @Expect(inheritedJar.headerFor(HttpUrl.parse("https://victim.bar.kawasaki.jp/")), "")
        @Expect(inheritedJar.acceptSetCookie(
            "exception=valid; Domain=city.kawasaki.jp; Path=/",
            HttpUrl.parse("https://app.city.kawasaki.jp/")
        ))
        @Expect(inheritedJar.headerFor(HttpUrl.parse("https://api.city.kawasaki.jp/")), "exception=valid")

        let privateJar = CookieJar()
        @Expect(!privateJar.acceptSetCookie(
            "private=stolen; Domain=blogspot.com; Path=/",
            HttpUrl.parse("https://attacker.blogspot.com/")
        ))
        @Expect(privateJar.acceptSetCookie(
            "private=valid; Domain=tenant.blogspot.com; Path=/",
            HttpUrl.parse("https://app.tenant.blogspot.com/")
        ))
        @Expect(privateJar.headerFor(HttpUrl.parse("https://victim.blogspot.com/")), "")
        @Expect(privateJar.headerFor(HttpUrl.parse("https://api.tenant.blogspot.com/")), "private=valid")

        let idnJar = CookieJar()
        @Expect(!idnJar.acceptSetCookie(
            "idn=stolen; Domain=xn--55qx5d.cn; Path=/",
            HttpUrl.parse("https://attacker.xn--55qx5d.cn/")
        ))
        @Expect(idnJar.acceptSetCookie(
            "idn=valid; Domain=tenant.xn--55qx5d.cn; Path=/",
            HttpUrl.parse("https://app.tenant.xn--55qx5d.cn/")
        ))
        @Expect(idnJar.headerFor(HttpUrl.parse("https://victim.xn--55qx5d.cn/")), "")
        @Expect(idnJar.headerFor(HttpUrl.parse("https://api.tenant.xn--55qx5d.cn/")), "idn=valid")

        let stricterJar = CookieJar(rejectPublicSuffixes: ["example.co.uk"])
        @Expect(!stricterJar.acceptSetCookie(
            "strict=no; Domain=example.co.uk; Path=/",
            HttpUrl.parse("https://app.example.co.uk/")
        ))
    }

    @TestCase
    func defaultPathAndPathMatchUseDirectoryAndSlashBoundaries(): Unit {
        let jar = CookieJar()
        let origin = HttpUrl.parse("https://example.test/docs/Web/index.html?source=cookie")
        @Expect(jar.acceptSetCookie("defaulted=yes", origin))
        @Expect(jar.acceptSetCookie("root=yes; Path=/", origin))
        @Expect(jar.acceptSetCookie("exact=yes; Path=/docs/Web/index.html", origin))

        @Expect(jar.headerFor(HttpUrl.parse("https://example.test/docs/Web/next")),
            "defaulted=yes; root=yes")
        @Expect(jar.headerFor(HttpUrl.parse("https://example.test/docs/Webish/next")), "root=yes")
        @Expect(jar.headerFor(HttpUrl.parse("https://example.test/docs/Web/index.html")),
            "exact=yes; defaulted=yes; root=yes")
    }

    @TestCase
    func maxAgeTakesPrecedenceAndNonPositiveValuesDeleteTheIdentity(): Unit {
        let jar = CookieJar()
        let url = HttpUrl.parse("https://example.test/")
        @Expect(jar.acceptSetCookie(
            "life=alive; Expires=Wed, 09 Jun 2021 10:18:14 GMT; Max-Age=60; Path=/",
            url
        ))
        @Expect(jar.headerFor(url), "life=alive")
        @Expect(jar.acceptSetCookie(
            "life=gone; Expires=Wed, 09 Jun 2038 10:18:14 GMT; Max-Age=0; Path=/",
            url
        ))
        @Expect(jar.headerFor(url), "")

        @Expect(jar.acceptSetCookie("expired=value; Path=/", url))
        @Expect(jar.acceptSetCookie(
            "expired=value; Expires=Wed, 09 Jun 2021 10:18:14 GMT; Path=/",
            url
        ))
        @Expect(jar.headerFor(url), "")
    }

    @TestCase
    func secureMetadataControlsTransportAndHttpOnlyDoesNotChangeWireSelection(): Unit {
        let jar = CookieJar()
        let secureUrl = HttpUrl.parse("https://example.test/")
        @Expect(jar.acceptSetCookie("secret=x; Secure; HttpOnly; Path=/", secureUrl))
        @Expect(jar.headerFor(secureUrl), "secret=x")
        @Expect(jar.headerFor(HttpUrl.parse("http://example.test/")), "")
        let snapshot = jar.snapshot()
        @Expect(snapshot[0].secure)
        @Expect(snapshot[0].httpOnly)
    }

    @TestCase
    func valuedSecureAttributeCannotLeakCookiesToCleartext(): Unit {
        let jar = CookieJar()
        let origin = HttpUrl.parse("https://example.test/")
        @Expect(jar.acceptSetCookie("secret=x; Secure=1; HttpOnly=; Path=/", origin))
        @Expect(jar.headerFor(origin), "secret=x")
        @Expect(jar.headerFor(HttpUrl.parse("http://example.test/")), "")
        @Expect(jar.snapshot()[0].httpOnly)
    }

    @TestCase
    func cleartextOriginsCannotCreateOrOverlaySecureCookies(): Unit {
        let jar = CookieJar()
        let secureOrigin = HttpUrl.parse("https://app.example.test/account/login")
        let clearOrigin = HttpUrl.parse("http://app.example.test/account/login")
        @Expect(!jar.store(Cookie("direct", "bad", path: "/", secure: true), clearOrigin))
        @Expect(!jar.acceptSetCookie("parsed=bad; Secure; Path=/", clearOrigin))
        @Expect(jar.snapshot().isEmpty())

        @Expect(jar.acceptSetCookie("host=good; Secure; Path=/account", secureOrigin))
        @Expect(jar.acceptSetCookie(
            "domain=good; Domain=example.test; Secure; Path=/account",
            secureOrigin
        ))
        @Expect(!jar.acceptSetCookie(
            "host=overlay; Domain=example.test; Path=/account/profile",
            clearOrigin
        ))
        @Expect(!jar.acceptSetCookie("host=deleted; Max-Age=0; Path=/account", clearOrigin))
        @Expect(!jar.store(
            Cookie("domain", "deleted", maxAge: Some(0), domain: "example.test", path: "/account"),
            clearOrigin
        ))
        @Expect(!jar.store(
            Cookie("domain", "overlay", path: "/account/profile"),
            clearOrigin
        ))

        @Expect(jar.headerFor(HttpUrl.parse("https://app.example.test/account/profile")),
            "host=good; domain=good")
        @Expect(jar.snapshot().size, 2)

        // A sibling path does not overlay the secure /account scope.
        @Expect(jar.acceptSetCookie("host=sibling; Path=/accounting", clearOrigin))
        @Expect(jar.headerFor(HttpUrl.parse("http://app.example.test/accounting")), "host=sibling")
        @Expect(jar.headerFor(HttpUrl.parse("https://app.example.test/account/profile")),
            "host=good; domain=good")
    }

    @TestCase
    func cleartextQuotaFloodCannotEvictSecureIdentityAndInstallReplacement(): Unit {
        let jar = CookieJar(maximumCookies: 2)
        let secureOrigin = HttpUrl.parse("https://example.test/")
        let clearOrigin = HttpUrl.parse("http://example.test/")
        @Expect(jar.acceptSetCookie("session=trusted; Secure; Path=/", secureOrigin))
        @Expect(jar.acceptSetCookie("ordinary=initial; Path=/", clearOrigin))
        for (index in 0..8) {
            @Expect(jar.acceptSetCookie("flood${index}=attacker; Path=/", clearOrigin))
        }
        @Expect(!jar.acceptSetCookie("session=attacker; Path=/", clearOrigin))
        @Expect(jar.headerFor(secureOrigin), "session=trusted; flood7=attacker")
        @Expect(jar.headerFor(clearOrigin), "flood7=attacker")
    }

    @TestCase
    func allSecureQuotaRejectsCleartextInsertionsFromBothStorageEntrypoints(): Unit {
        let jar = CookieJar(maximumCookies: 1)
        let secureOrigin = HttpUrl.parse("https://example.test/")
        let clearOrigin = HttpUrl.parse("http://unrelated.test/")
        @Expect(jar.store(Cookie("session", "trusted", path: "/", secure: true), secureOrigin))
        @Expect(!jar.acceptSetCookie("flood=parsed; Path=/", clearOrigin))
        @Expect(!jar.store(Cookie("flood", "direct", path: "/"), clearOrigin))
        @Expect(jar.acceptSetCookie("missing=deleted; Max-Age=0; Path=/", clearOrigin))
        @Expect(jar.headerFor(secureOrigin), "session=trusted")
        @Expect(jar.headerFor(clearOrigin), "")
        @Expect(jar.acceptSetCookie("session=renewed; Secure; Path=/", secureOrigin))
        @Expect(jar.headerFor(secureOrigin), "session=renewed")
        @Expect(jar.acceptSetCookie("replacement=authorized; Path=/", secureOrigin))
        @Expect(jar.headerFor(secureOrigin), "replacement=authorized")
    }

    @TestCase
    func rejectsHeaderInjectionAndInvalidCookieOctetsBeforeStorage(): Unit {
        let jar = CookieJar()
        let url = HttpUrl.parse("https://example.test/")
        for (value in [
            "safe=x\r\nX-Evil: yes",
            "bad name=value",
            "bad=value with space",
            "bad=quoted; Path=/\u{007f}"
        ]) {
            @Expect(!jar.acceptSetCookie(value, url))
        }
        @ExpectThrows[IllegalArgumentException](Cookie("bad=name", "value"))
        @ExpectThrows[IllegalArgumentException](Cookie("name", "line\nfeed"))
        @Expect(jar.snapshot().isEmpty())
    }

    @TestCase
    func capacityHeaderBoundsAndReplacementRemainDeterministic(): Unit {
        let url = HttpUrl.parse("https://example.test/deep/page")
        let jar = CookieJar(maximumCookies: 3, maximumHeaderBytes: 18)
        @Expect(jar.acceptSetCookie("old=1; Path=/", url))
        @Expect(jar.acceptSetCookie("id=root; Path=/", url))
        @Expect(jar.acceptSetCookie("id=deep; Path=/deep", url))
        @Expect(jar.acceptSetCookie("new=2; Path=/", url))
        @Expect(jar.snapshot().size, 3)
        @Expect(jar.headerFor(url), "id=deep; id=root")

        @Expect(jar.acceptSetCookie("id=replaced; Path=/", url))
        @Expect(jar.headerFor(url), "id=deep")
        @Expect(jar.snapshot().size, 3)
    }

    @TestCase
    func removalClearAndSnapshotsExposeOnlyLiveImmutableCookies(): Unit {
        let jar = CookieJar()
        let first = HttpUrl.parse("https://one.test/")
        let second = HttpUrl.parse("https://two.test/")
        @Expect(jar.acceptSetCookie("a=1; Path=/", first))
        @Expect(jar.acceptSetCookie("b=2; Path=/", second))
        let before = jar.snapshot()
        @Expect(before.size, 2)
        @Expect(jar.remove("a", first))
        @Expect(!jar.remove("a", first))
        @Expect(jar.headerFor(first), "")
        @Expect(jar.headerFor(second), "b=2")
        @Expect(jar.removeCookies("two.test"), 1)
        @Expect(jar.snapshot().isEmpty())
        @Expect(jar.acceptSetCookie("c=3; Path=/", first))
        jar.clear()
        @Expect(jar.snapshot().isEmpty())
        @Expect(before.size, 2)
    }

    @TestCase
    func concurrentStoresAndReadsRemainRaceFreeAndBounded(): Unit {
        let jar = CookieJar(maximumCookies: 64, maximumHeaderBytes: 8192)
        let url = HttpUrl.parse("https://concurrent.test/")
        let writers = ArrayList<Future<Bool>>()
        for (index in 0..32) {
            let captured = index
            writers.add(spawn {
                jar.acceptSetCookie("c${captured}=v${captured}; Path=/", url)
            })
        }
        for (writer in writers) { @Expect(writer.get()) }

        let readers = ArrayList<Future<String>>()
        for (_ in 0..16) { readers.add(spawn { jar.headerFor(url) }) }
        for (reader in readers) {
            let header = reader.get()
            @Expect(header.contains("c0=v0"))
            @Expect(header.contains("c31=v31"))
        }
        @Expect(jar.snapshot().size, 32)
    }

    @TestCase
    func boundedSetCookieMutationsPreserveScopeAndHeaderSafety(): Unit {
        let origin = HttpUrl.parse("https://app.example.test/app/page")
        let clearOrigin = HttpUrl.parse("http://app.example.test/app/page")
        let deepOrigin = HttpUrl.parse("https://deep.app.example.test/app/page")
        let exactPath = HttpUrl.parse("https://app.example.test/app")
        let childPath = HttpUrl.parse("https://app.example.test/app/child")
        let siblingPath = HttpUrl.parse("https://app.example.test/application")
        let unrelated = [
            HttpUrl.parse("https://evil.test/app/page"),
            HttpUrl.parse("https://notexample.test/app/page"),
            HttpUrl.parse("https://example.invalid/app/page")
        ]
        let seeds = [
            "sid=abc123; Path=/app; Secure; HttpOnly",
            "quoted=\"a:b/c?d\"; Domain=.example.test; Path=/app; Max-Age=3600",
            "expires=alive; Expires=Fri, 31 Dec 9999 23:59:59 GMT; Path=/app",
            "attrs=value; Domain=app.example.test; Path=/app; SameSite=Lax"
        ]

        // These controls anchor the mutation corpus in documented accepted forms.
        for (seed in seeds) {
            @Assert(m8005ExerciseSetCookieMutation(
                seed, origin, clearOrigin, deepOrigin, exactPath, childPath, siblingPath, unrelated
            ))
        }
        @Assert(m8005ExerciseSetCookieMutation(
            " spaced = \"value\" ; Path = /app ; Secure ",
            origin, clearOrigin, deepOrigin, exactPath, childPath, siblingPath, unrelated
        ))
        @Assert(m8005ExerciseSetCookieMutation(
            "equals=name=value; Path=/app",
            origin, clearOrigin, deepOrigin, exactPath, childPath, siblingPath, unrelated
        ))
        @Assert(m8005ExerciseSetCookieMutation(
            "defaulted=x; Path; Secure",
            origin, clearOrigin, deepOrigin, exactPath, childPath, siblingPath, unrelated
        ))

        // Malformed pair delimiters, names, values, quotes, and control bytes are rejected.
        for (invalid in [
            "", "missing-pair", "=empty-name", "; Path=/app", "bad name=value",
            "bad=value with space", "comma=value,other", "unterminated=\"value",
            "trailing=\"value\"junk", "empty-domain=x; Domain=; Path=/app",
            "bad-domain=x; Domain==example.test; Path=/app",
            "inject=x\r\nX-Evil: yes", "tab=x\tvalue", "nul=x\u{0000}; Path=/app",
            "delete=x\u{007f}; Path=/app"
        ]) {
            @Assert(!m8005ExerciseSetCookieMutation(
                invalid, origin, clearOrigin, deepOrigin, exactPath, childPath, siblingPath, unrelated
            ))
        }

        // Unknown malformed attributes cannot turn a host-only cookie into a domain or secure cookie.
        let malformedAttributeJar = CookieJar(
            maximumCookies: 2, maximumHeaderBytes: 128, rejectPublicSuffixes: ["com", "co.uk"]
        )
        @Assert(malformedAttributeJar.acceptSetCookie(
            "scope=x; Do main=evil.test; Sec ure; Path=/app", origin
        ))
        let malformedAttribute = malformedAttributeJar.snapshot()[0]
        @Assert(malformedAttribute.domain, "")
        @Assert(!malformedAttribute.secure)
        @Assert(malformedAttributeJar.headerFor(clearOrigin), "scope=x")
        @Assert(malformedAttributeJar.headerFor(deepOrigin), "")

        // Invalid expiry syntax is ignored, while a non-positive valid Max-Age deletes immediately.
        let invalidLifetimeJar = CookieJar(maximumCookies: 2, maximumHeaderBytes: 128)
        @Assert(invalidLifetimeJar.acceptSetCookie(
            "bad-max=x; Max-Age=+60; Expires=not-a-date; Path=/app", origin
        ))
        @Assert(invalidLifetimeJar.snapshot()[0].maxAge.isNone())
        @Assert(invalidLifetimeJar.snapshot()[0].expires.isNone())
        @Assert(invalidLifetimeJar.headerFor(origin), "bad-max=x")
        let deletionJar = CookieJar(maximumCookies: 2, maximumHeaderBytes: 128)
        @Assert(deletionJar.acceptSetCookie("gone=x; Max-Age=0; Path=/app", origin))
        @Assert(deletionJar.snapshot().isEmpty())
        @Assert(deletionJar.headerFor(origin), "")

        // Domain labels are accepted at 63 bytes and rejected beyond it or at invalid edges.
        let label63 = String.fromUtf8(Array<Byte>(63, repeat: b'a'))
        let label64 = String.fromUtf8(Array<Byte>(64, repeat: b'a'))
        let labelOrigin = HttpUrl.parse("https://app.${label63}.test/app/page")
        let labelJar = CookieJar(maximumCookies: 2, maximumHeaderBytes: 128)
        @Assert(labelJar.acceptSetCookie(
            "boundary=x; Domain=${label63}.test; Path=/app", labelOrigin
        ))
        @Assert(labelJar.headerFor(
            HttpUrl.parse("https://deep.app.${label63}.test/app/page")
        ), "boundary=x")
        for (domain in [
            "${label64}.example.test", "-example.test", "example-.test",
            "example..test", "example.test.", "_example.test"
        ]) {
            let jar = CookieJar(maximumCookies: 2, maximumHeaderBytes: 128)
            @Assert(!jar.acceptSetCookie("boundary=x; Domain=${domain}; Path=/app", origin))
            @Assert(jar.snapshot().isEmpty())
        }

        let foreignJar = CookieJar(maximumCookies: 2, maximumHeaderBytes: 128)
        @Assert(!foreignJar.acceptSetCookie(
            "foreign=x; Domain=evil.test; Path=/app", origin
        ))
        @Assert(foreignJar.snapshot().isEmpty())
        let suffixOrigin = HttpUrl.parse("https://app.example.co.uk/app/page")
        let suffixJar = CookieJar(
            maximumCookies: 2, maximumHeaderBytes: 128, rejectPublicSuffixes: ["com", "co.uk"]
        )
        @Assert(!suffixJar.acceptSetCookie(
            "suffix=x; Domain=co.uk; Path=/app", suffixOrigin
        ))
        @Assert(suffixJar.snapshot().isEmpty())

        let replacements = [
            0u8, 9u8, 13u8, 31u8, 32u8, 34u8, 40u8, 44u8, 45u8,
            46u8, 47u8, 58u8, 59u8, 61u8, 92u8, 126u8, 127u8
        ]
        var iterations: Int64 = 0
        var accepted: Int64 = 0
        var rejected: Int64 = 0
        for (seed in seeds) {
            let bytes = seed.toArray()
            for (index in 0..bytes.size) {
                for (replacement in replacements) {
                    let mutated = bytes.clone()
                    mutated[index] = replacement
                    let candidate = String.fromUtf8(mutated)
                    if (m8005ExerciseSetCookieMutation(
                        candidate, origin, clearOrigin, deepOrigin,
                        exactPath, childPath, siblingPath, unrelated
                    )) {
                        accepted++
                    } else {
                        rejected++
                    }
                    iterations++
                }
                let shortened = m8005CookieDeleteByte(bytes, index)
                if (m8005ExerciseSetCookieMutation(
                    shortened, origin, clearOrigin, deepOrigin,
                    exactPath, childPath, siblingPath, unrelated
                )) {
                    accepted++
                } else {
                    rejected++
                }
                iterations++
            }
        }
        println(
            "M8005_FUZZ target=set-cookie seed=8005 iterations=${iterations} " +
                "accepted=${accepted} rejected=${rejected} decision=PASS"
        )
    }
}

private func m8005ExerciseSetCookieMutation(
    candidate: String,
    origin: HttpUrl,
    clearOrigin: HttpUrl,
    deepOrigin: HttpUrl,
    exactPath: HttpUrl,
    childPath: HttpUrl,
    siblingPath: HttpUrl,
    unrelated: Array<HttpUrl>
): Bool {
    let jar = CookieJar(
        maximumCookies: 2, maximumHeaderBytes: 128, rejectPublicSuffixes: ["com", "co.uk"]
    )
    let accepted = jar.acceptSetCookie(candidate, origin)
    let selected = jar.cookiesFor(origin)
    let header = jar.headerFor(origin)
    @Assert(m8005CookieHeaderIsSafe(header))
    @Assert(header.size <= jar.maximumHeaderBytes)
    @Assert(selected.isEmpty(), header.isEmpty())
    if (!selected.isEmpty()) {
        @Assert(selected.size, 1)
        @Assert(header, "${selected[0].cookieName}=${selected[0].cookieValue}")
    }
    for (url in unrelated) {
        @Assert(jar.cookiesFor(url).isEmpty())
        @Assert(jar.headerFor(url), "")
    }

    let live = jar.snapshot()
    if (!accepted) { @Assert(live.isEmpty()) }
    for (cookie in live) {
        if (cookie.secure) {
            @Assert(jar.cookiesFor(clearOrigin).isEmpty())
            @Assert(jar.headerFor(clearOrigin), "")
        }
        if (cookie.domain.isEmpty()) {
            @Assert(jar.cookiesFor(deepOrigin).isEmpty())
            @Assert(jar.headerFor(deepOrigin), "")
        } else if (!selected.isEmpty()) {
            @Assert(jar.cookiesFor(deepOrigin).size, selected.size)
            @Assert(jar.headerFor(deepOrigin), header)
        }
        if (cookie.path == "/app") {
            @Assert(!jar.cookiesFor(exactPath).isEmpty())
            @Assert(jar.headerFor(exactPath), header)
            @Assert(jar.headerFor(childPath), header)
            @Assert(jar.cookiesFor(siblingPath).isEmpty())
            @Assert(jar.headerFor(siblingPath), "")
        }
    }
    accepted
}

private func m8005CookieHeaderIsSafe(value: String): Bool {
    for (byte in value.toArray()) {
        if (byte < 32u8 || byte >= 127u8) { return false }
    }
    true
}

private func m8005CookieDeleteByte(bytes: Array<Byte>, removed: Int64): String {
    let output = Array<Byte>(bytes.size - 1, repeat: 0u8)
    var at: Int64 = 0
    for (index in 0..bytes.size) {
        if (index != removed) {
            output[at] = bytes[index]
            at++
        }
    }
    String.fromUtf8(output)
}
