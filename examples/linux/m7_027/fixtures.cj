package wirestack_m7_027_examples

import std.collection.ArrayList

// Test-only self-signed identity for example.com, valid 2026-08-23 to 2036-08-20.
func exampleCertificateDer(): Array<Byte> {
    decodeExampleBase64(
        "MIIDQzCCAiugAwIBAgIUDZ6pPmV6gcjC9tTovgITROZDWi4wDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMB4XDTI2MDgyMzIwMTkyOFoXDTM2MDgyMDIwMTkyOFowGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3+ICzVHaQ8+czxeV/aeg/iAIgwhqYytRVc17/BY3XdLtYSaG9O6wYxtqm5zZvcujcl35vStEEIc6RsXpQxAUzGp6Gq129MTDzdyW5a7x63bWC6Zlh6SpC4zFdt/xGJisJw/HS4LHLXKzQiSwHZPwFN7zOZ0JMAh05BLF4yEOwkbiqYUR3i7z0wVtvUFuL3NAGfZXzXY1HRi+Qfm/h9lbrMmQtm3kBGBmZUh8ASqugcfiCMziYYY1ygZw1MACxJ60nRfvq1wYVZdUmiD2WED4NF0VK58tP/qJ0KnKz/I2g4GcV5Xu1tH/2NYaI8YT2ejIQn6TgwYWN+3HaXe3Q83DQwIDAQABo4GAMH4wHQYDVR0OBBYEFOdUzp+rhoI4EOD+k/HiZeHgTdcEMB8GA1UdIwQYMBaAFOdUzp+rhoI4EOD+k/HiZeHgTdcEMA8GA1UdEwEB/wQFMAMBAf8wKwYDVR0RBCQwIoILZXhhbXBsZS5jb22CDSouZXhhbXBsZS5vcmeHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBALHiaFne/TJfVzznruLWTPKpQV/+dZKhPw8X2umZ1fLd6/sD2xtoeDof2IOx+HqQJuQNFNY8lAHsCb5J72/O5rXBhHHbYxwTL/LuAo9fKbCCwxp10Y5gwPrEcl5T1ZlsAgPTKq10ONwNR03wefE6epejITvX2nCNJUiaf3BWzFiq5xsZXfUHoil/AqAJfqnAgiABoOs/ZxErf0q16Apr4rjFvreAwsiYr1YgJ4aL97j3jCvJUNreGr8TNUBachUSrRvWcOOTaw90eex/6DnvU1EHDknlmcuuzywawVNzrTd10EuHimVfJgo1hRSzXd4deCHKStlYkPKZpwU/M+Al8F0="
    )
}

func examplePrivateKeyDer(): Array<Byte> {
    decodeExampleBase64(
        "MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDf4gLNUdpDz5zPF5X9p6D+IAiDCGpjK1FVzXv8Fjdd0u1hJob07rBjG2qbnNm9y6NyXfm9K0QQhzpGxelDEBTManoarXb0xMPN3JblrvHrdtYLpmWHpKkLjMV23/EYmKwnD8dLgsctcrNCJLAdk/AU3vM5nQkwCHTkEsXjIQ7CRuKphRHeLvPTBW29QW4vc0AZ9lfNdjUdGL5B+b+H2VusyZC2beQEYGZlSHwBKq6Bx+IIzOJhhjXKBnDUwALEnrSdF++rXBhVl1SaIPZYQPg0XRUrny0/+onQqcrP8jaDgZxXle7W0f/Y1hojxhPZ6MhCfpODBhY37cdpd7dDzcNDAgMBAAECggEAKz/5o5l27VerptQbHTPnZYBhtJKJHtxM66L1GzddfcoUIorzUljUCWlP+HzeEYzH5/2gk7tKfFjrWKW+EL8IDY9aRFITY2ipnNjK69cWlBLSedCs133nTDxnHzZW2JYR17/0E7HRcYWxfIsi3KvqGtYRLaWZE0bm8fJweRa3R69WXYsZOYDK1CDMmrGZ572+5thDTVaiQKOOUBPNgucnB894rYtLYs98sb+2h4EUHZ0cQCIBUVdwu6BAFMwiAEtz2CClwA1G2fq59A9mqQXSkj8WaUHUgo9WcExt6pBEb5MPca+BHWz/aqdC9HRKQFBl3kn4h0qEGkLSy0WrMLKm7QKBgQD6fmd1BDrlsgbLoai3NnrnqKVbn8+0vnJjmTTykxeYHQXxBt3fzH+t42crJowQbuLeoO20oUY0VU8eQVh7bWvduucfFqrecLCL6GhhAFxp2dMjgOdvIim3QN9kvTSUlwOYchA43RTA7wWSzUf1+bL1XWs5bUNg5azpN0Btkma5xQKBgQDkzdwslfjcZgOp1QX2oSPOaA1VuOEJnr3+I2SR8FNH+bVwfbrilF5Mm08jHHHgoqgnGZLG7GLIgQAU1PmIr84hB7CE3JM9xXJ3t0jZ7BktfJEHLzog2Dr6vzXGT+yDcd2q1Lr3GL6x18Y+kgv6ieLv047SOBLal4o8iEjj9PZBZwKBgQCEzx4VKZ/8hq4ZquVj9iulxYGemZWrc8n8So+LCTfaO5EZ4JUkgi0zyby6YR6j29bHSLWfLl6lgpGHLgg2sKYfEmhV0FPZyg+griEhROq6aHYMfdy2zHsnoOqQY8yL96E9Y0R8kaLeRBxFYDeGD9S1SMl/0hGGP1+06slrDtMOLQKBgQCGArDviFN/O1zv7u4UOuNO9JDC4Ysk6E4deLth4uHUaURFA88fAImO0vRx+yoTyRE1/XuDeVaOW0gh62/QCDByFh/kYZD4ABqAVeCcivVgN/J1w8qHDD7XOIEViyBbCKktcnWjXmHqphfd9AqCDprVnxKqu98HGvUDaUtQANzvBwKBgQDJkuAOZocXTl77PfxDWfsP57StrsiuL+AvoH2FscRcT19e9T2U4YuCsyVydRM+gjUoJX5VPedIo+/gcvJrQcJIfwzZlqMMEJnYcWjoG8GYVtub9/xxSPmfuyj3GDbXEcirKkmGOmI5hPEP2UIasTUeljm8sHSP2B52kyKmdVGuUg=="
    )
}

private func decodeExampleBase64(value: String): Array<Byte> {
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
        } else if (byte == b'+') { 62 }
        else if (byte == b'/') { 63 }
        else { throw IllegalArgumentException("invalid example TLS fixture") }
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

