package wirestack.internal.tls_engine

import std.collection.*
import wirestack.internal.trust.*

// Test-only self-signed identity. The private key is intentionally public test data.
// Validity: 2026-08-23T20:19:28Z through 2036-08-20T20:19:28Z.
func tlsTestCertificateDer(): Array<Byte> {
    decodeTlsTestBase64(
        "MIIDQzCCAiugAwIBAgIUDZ6pPmV6gcjC9tTovgITROZDWi4wDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMB4XDTI2MDgyMzIwMTkyOFoXDTM2MDgyMDIwMTkyOFowGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3+ICzVHaQ8+czxeV/aeg/iAIgwhqYytRVc17/BY3XdLtYSaG9O6wYxtqm5zZvcujcl35vStEEIc6RsXpQxAUzGp6Gq129MTDzdyW5a7x63bWC6Zlh6SpC4zFdt/xGJisJw/HS4LHLXKzQiSwHZPwFN7zOZ0JMAh05BLF4yEOwkbiqYUR3i7z0wVtvUFuL3NAGfZXzXY1HRi+Qfm/h9lbrMmQtm3kBGBmZUh8ASqugcfiCMziYYY1ygZw1MACxJ60nRfvq1wYVZdUmiD2WED4NF0VK58tP/qJ0KnKz/I2g4GcV5Xu1tH/2NYaI8YT2ejIQn6TgwYWN+3HaXe3Q83DQwIDAQABo4GAMH4wHQYDVR0OBBYEFOdUzp+rhoI4EOD+k/HiZeHgTdcEMB8GA1UdIwQYMBaAFOdUzp+rhoI4EOD+k/HiZeHgTdcEMA8GA1UdEwEB/wQFMAMBAf8wKwYDVR0RBCQwIoILZXhhbXBsZS5jb22CDSouZXhhbXBsZS5vcmeHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBALHiaFne/TJfVzznruLWTPKpQV/+dZKhPw8X2umZ1fLd6/sD2xtoeDof2IOx+HqQJuQNFNY8lAHsCb5J72/O5rXBhHHbYxwTL/LuAo9fKbCCwxp10Y5gwPrEcl5T1ZlsAgPTKq10ONwNR03wefE6epejITvX2nCNJUiaf3BWzFiq5xsZXfUHoil/AqAJfqnAgiABoOs/ZxErf0q16Apr4rjFvreAwsiYr1YgJ4aL97j3jCvJUNreGr8TNUBachUSrRvWcOOTaw90eex/6DnvU1EHDknlmcuuzywawVNzrTd10EuHimVfJgo1hRSzXd4deCHKStlYkPKZpwU/M+Al8F0="
    )
}

func tlsTestPrivateKeyDer(): Array<Byte> {
    decodeTlsTestBase64(
        "MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDf4gLNUdpDz5zPF5X9p6D+IAiDCGpjK1FVzXv8Fjdd0u1hJob07rBjG2qbnNm9y6NyXfm9K0QQhzpGxelDEBTManoarXb0xMPN3JblrvHrdtYLpmWHpKkLjMV23/EYmKwnD8dLgsctcrNCJLAdk/AU3vM5nQkwCHTkEsXjIQ7CRuKphRHeLvPTBW29QW4vc0AZ9lfNdjUdGL5B+b+H2VusyZC2beQEYGZlSHwBKq6Bx+IIzOJhhjXKBnDUwALEnrSdF++rXBhVl1SaIPZYQPg0XRUrny0/+onQqcrP8jaDgZxXle7W0f/Y1hojxhPZ6MhCfpODBhY37cdpd7dDzcNDAgMBAAECggEAKz/5o5l27VerptQbHTPnZYBhtJKJHtxM66L1GzddfcoUIorzUljUCWlP+HzeEYzH5/2gk7tKfFjrWKW+EL8IDY9aRFITY2ipnNjK69cWlBLSedCs133nTDxnHzZW2JYR17/0E7HRcYWxfIsi3KvqGtYRLaWZE0bm8fJweRa3R69WXYsZOYDK1CDMmrGZ572+5thDTVaiQKOOUBPNgucnB894rYtLYs98sb+2h4EUHZ0cQCIBUVdwu6BAFMwiAEtz2CClwA1G2fq59A9mqQXSkj8WaUHUgo9WcExt6pBEb5MPca+BHWz/aqdC9HRKQFBl3kn4h0qEGkLSy0WrMLKm7QKBgQD6fmd1BDrlsgbLoai3NnrnqKVbn8+0vnJjmTTykxeYHQXxBt3fzH+t42crJowQbuLeoO20oUY0VU8eQVh7bWvduucfFqrecLCL6GhhAFxp2dMjgOdvIim3QN9kvTSUlwOYchA43RTA7wWSzUf1+bL1XWs5bUNg5azpN0Btkma5xQKBgQDkzdwslfjcZgOp1QX2oSPOaA1VuOEJnr3+I2SR8FNH+bVwfbrilF5Mm08jHHHgoqgnGZLG7GLIgQAU1PmIr84hB7CE3JM9xXJ3t0jZ7BktfJEHLzog2Dr6vzXGT+yDcd2q1Lr3GL6x18Y+kgv6ieLv047SOBLal4o8iEjj9PZBZwKBgQCEzx4VKZ/8hq4ZquVj9iulxYGemZWrc8n8So+LCTfaO5EZ4JUkgi0zyby6YR6j29bHSLWfLl6lgpGHLgg2sKYfEmhV0FPZyg+griEhROq6aHYMfdy2zHsnoOqQY8yL96E9Y0R8kaLeRBxFYDeGD9S1SMl/0hGGP1+06slrDtMOLQKBgQCGArDviFN/O1zv7u4UOuNO9JDC4Ysk6E4deLth4uHUaURFA88fAImO0vRx+yoTyRE1/XuDeVaOW0gh62/QCDByFh/kYZD4ABqAVeCcivVgN/J1w8qHDD7XOIEViyBbCKktcnWjXmHqphfd9AqCDprVnxKqu98HGvUDaUtQANzvBwKBgQDJkuAOZocXTl77PfxDWfsP57StrsiuL+AvoH2FscRcT19e9T2U4YuCsyVydRM+gjUoJX5VPedIo+/gcvJrQcJIfwzZlqMMEJnYcWjoG8GYVtub9/xxSPmfuyj3GDbXEcirKkmGOmI5hPEP2UIasTUeljm8sHSP2B52kyKmdVGuUg=="
    )
}

func tlsTestSubjectPublicKeyInfoDer(): Array<Byte> {
    decodeTlsTestBase64(
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3+ICzVHaQ8+czxeV/aeg/iAIgwhqYytRVc17/BY3XdLtYSaG9O6wYxtqm5zZvcujcl35vStEEIc6RsXpQxAUzGp6Gq129MTDzdyW5a7x63bWC6Zlh6SpC4zFdt/xGJisJw/HS4LHLXKzQiSwHZPwFN7zOZ0JMAh05BLF4yEOwkbiqYUR3i7z0wVtvUFuL3NAGfZXzXY1HRi+Qfm/h9lbrMmQtm3kBGBmZUh8ASqugcfiCMziYYY1ygZw1MACxJ60nRfvq1wYVZdUmiD2WED4NF0VK58tP/qJ0KnKz/I2g4GcV5Xu1tH/2NYaI8YT2ejIQn6TgwYWN+3HaXe3Q83DQwIDAQAB"
    )
}

func tlsAltTestCertificateDer(): Array<Byte> {
    decodeTlsTestBase64(
        "MIIDMTCCAhmgAwIBAgIUDhmbdFrT3IHusW6vNxqiy2c5DQ0wDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPYWx0LmV4YW1wbGUuY29tMB4XDTI2MDgyMzIxMDkzOFoXDTM2MDgyMDIxMDkzOFowGjEYMBYGA1UEAwwPYWx0LmV4YW1wbGUuY29tMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA5rFA+gKHS+7XpIbOdAfF44wQYGY2T1e+ThHicQA80uucAYEmzG0ue6/wOdsMzCilFyrA7lxO10lgswr8POrzty38ODsld7iHgu5gGvA+0WuAntIT/zQv09mycmwWVU5mOaAiVVhYyIdtoptPhbHj6D6WQrjCI9PPKog0EVUal92OzInzImlICwUnPK5iPwT6L8Qcb/xH9tvRrHklh5+4iGSHozCPF5kxsKMDcnbMoYtgYAAphE/TCtbzeZByD0LRTlmK9P1MxwQtWkLgwwt1oWZAGNNPO/dTeYbBOVUH/AF5xNm0O19IEXxkt7rQtG/EGW3qBqhWU++psuotL+AtqwIDAQABo28wbTAdBgNVHQ4EFgQUHVvjclKDynfVBG/HTshWeQBmrNcwHwYDVR0jBBgwFoAUHVvjclKDynfVBG/HTshWeQBmrNcwDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgg9hbHQuZXhhbXBsZS5jb20wDQYJKoZIhvcNAQELBQADggEBALjEvk7kxaY0kN364m5XHj1vR2vv6Lank0vzZbXcc60DcYdZazbt4qV9KJvYt2KuXdFmtklwVgvcNKAnluuCrcP2uvMy+05dwGXJwPobw/tQf9S8V3LgBlD20wVGQsn55wD02MHSpFFD2FzPFmbELrUWgZPv7ubQzDblxb2isWP9AIORfy+Vm8Pi6aW8XcpM0kUZEfVL+UGnG8kGMkkzyHsWm6CxR1fQJpEJQ7Wa+Gp+epAam97HSzcvSzaNii7b4qqo0l3093yVURXHlNfs/ptzeIiw89jwk2j8ftl7gLfssDBSPvZDi+FIWvgi0wEoQP0Z0yE2LEd0AJnZK7rAnkQ="
    )
}

func tlsAltTestPrivateKeyDer(): Array<Byte> {
    decodeTlsTestBase64(
        "MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDmsUD6AodL7tekhs50B8XjjBBgZjZPV75OEeJxADzS65wBgSbMbS57r/A52wzMKKUXKsDuXE7XSWCzCvw86vO3Lfw4OyV3uIeC7mAa8D7Ra4Ce0hP/NC/T2bJybBZVTmY5oCJVWFjIh22im0+FsePoPpZCuMIj088qiDQRVRqX3Y7MifMiaUgLBSc8rmI/BPovxBxv/Ef229GseSWHn7iIZIejMI8XmTGwowNydsyhi2BgACmET9MK1vN5kHIPQtFOWYr0/UzHBC1aQuDDC3WhZkAY008791N5hsE5VQf8AXnE2bQ7X0gRfGS3utC0b8QZbeoGqFZT76my6i0v4C2rAgMBAAECggEAWcSTwjWFrFiOdSk34RK9QGRaYwijDZDZLsvqz4oGIRUpqbQ2AsphkiPOWNUST8dpJnCujpJA46lcBY+6w4GxwJAWW1M4qzOVF6/mmdTuvNMWQ7b/rQkDq25E8B17O0q8oKPdeFReh/mbAfFpql6kjtT75465jPN449YIXM4/AOSq1fl8qi+RxeIsuOwiBwrVCHSu28ZzWfEagNYC0EO5kzz4v4THNfqeaRDUVzL6x1XlXHU4wSl87gPxuvRcwFhIXh451Xu1jrVqz2sILMHKF5nXiNpwNQs5j469QEN7o/9AFnrLxOQ8nOU0jIoN984rvcPEZplBb6M5CdKLK4Q6IQKBgQD7TxKcgWng7hNAI8EZsAMxqHouarSmR7WPI2RVqaUawslrU9OQtwnH/5nk4TFTf3pRNCxoAUHxhUUwsAXfZ6/cinmOJlMEIDvqrw6gLiQry/4vTWmwmBQg9NluXz0NyIsCXOmptF5FdrChup1Yr8CTAj3pbx57fS3rp0Tm6UfJ+QKBgQDq/6lNo0OVjmt7agdfsghOurVeL3fdbdCWZakaaOKlaVjlsi+xZRlq0asLkxCmtFHcQLOFN59/WdVNTv3Bukudqu78RKQwp8vhC/TA1bEczq5xlAAvetYFVmWZ2oxNudkp1O0RN1GfrLTRxJKXlJ0q08Y8W2lpCMgeuaLGZ9k9wwKBgDu3ZW/FHLizOeXS2S7WcVvacfYXqwecIJt7yHrGjhIW2S/kwnAv3mYk6ZfGnyb9Mr6bDDZGnjna9j8EhNC6XcKlMQ9DMhTX6ATzRiFv9W5m0ebBmWy6JoZSSFx+yw48ajPMikWmM4SEGKLFqmAJm1QTg0y19+NWMpQ9shTAuCtZAoGBANBjjrruQIxrEx0J1SgjNAK8xwCSj3SoYQQ9ekuVHwcX+GEYNfrVcEitTUSiUW3DEaSDK67CuImyG9jGZ3hXv549algCdqc+5SjX9V7bIIgvL7pASDnSb9+j0c0xZKG4YL8btm5B4/v4pxAthOEuRIEp8uyrEzq1MuEsNRBEHv0JAoGBALbm2wI0A6oNbYjNPflpDO+MSXMGYjTtH5Vp4KejgDqWKxLtqdv2vft/FCoEYWXZPDsW70XNkJ0C++Qd5EDlv96ELs4PTGZ70dJE1FO3IDh69WTN3+e5jHWq3n/9F1Zws9AthDSitVEvRPQkHD7dcjORDlXHA/dG3+hDjZVc9gI0"
    )
}

func tlsAltTestLocalIdentity(): LocalIdentity {
    LocalIdentity(
        CertificateChain([DerCertificate(tlsAltTestCertificateDer())]),
        PrivateKeyRef.pkcs8(tlsAltTestPrivateKeyDer())
    )
}

func tlsTestSpkiPin(): SpkiSha256Pin {
    SpkiSha256Pin([
        0xff, 0xa0, 0x19, 0xf8, 0x3b, 0xe3, 0x10, 0x77,
        0x53, 0x96, 0x71, 0xba, 0xc2, 0xeb, 0x76, 0xfa,
        0x5c, 0x00, 0x3a, 0x68, 0x8f, 0xfb, 0x04, 0xe8,
        0x1a, 0x69, 0x57, 0x2e, 0xfe, 0xb9, 0xac, 0x8e
    ])
}

func tlsTestLocalIdentity(): LocalIdentity {
    LocalIdentity(
        CertificateChain([DerCertificate(tlsTestCertificateDer())]),
        PrivateKeyRef.pkcs8(tlsTestPrivateKeyDer())
    )
}

func decodeTlsTestBase64(value: String): Array<Byte> {
    let output = ArrayList<Byte>()
    var accumulator: Int64 = 0
    var bits: Int64 = 0
    for (byte in value.toArray()) {
        if (byte == b'=') { break }
        let decoded: Int64 = if (byte >= b'A' && byte <= b'Z') {
            Int64(byte - b'A')
        } else if (byte >= b'a' && byte <= b'z') {
            Int64(byte - b'a') + 26
        } else if (byte >= b'0' && byte <= b'9') {
            Int64(byte - b'0') + 52
        } else if (byte == b'+') {
            62
        } else if (byte == b'/') {
            63
        } else {
            throw IllegalArgumentException("invalid TLS test fixture")
        }
        accumulator = (accumulator << 6) | decoded
        bits += 6
        if (bits >= 8) {
            bits -= 8
            output.add(UInt8(UInt64((accumulator >> bits) & 0xff)))
            accumulator &= if (bits == 0) { 0 } else { (1 << bits) - 1 }
        }
    }
    output.toArray()
}
