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
}
