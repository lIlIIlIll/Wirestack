package wirestack.internal.connector

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*

private func ipv4(last: Byte): IpAddress {
    IpAddress(IpAddressFamily.Ipv4, [192, 0, 2, last])
}

private func ipv6(last: Byte, zone!: ?String = None<String>): IpAddress {
    let bytes = Array<Byte>(16, repeat: 0)
    bytes[0] = 0x20
    bytes[1] = 0x01
    bytes[15] = last
    IpAddress(IpAddressFamily.Ipv6, bytes, zone: zone)
}

@Test
class AttemptPlanTest {
    @TestCase
    func alternatesFamiliesAndPreservesFamilyOrder(): Unit {
        let plan = buildAttemptPlan([ipv6(1), ipv6(2), ipv4(1), ipv4(2), ipv6(3)], 443)
        let candidates = plan.candidates
        @Expect(candidates.size, 5)
        @Expect(candidates[0].endpoint.address, ipv6(1))
        @Expect(candidates[1].endpoint.address, ipv4(1))
        @Expect(candidates[2].endpoint.address, ipv6(2))
        @Expect(candidates[3].endpoint.address, ipv4(2))
        @Expect(candidates[4].endpoint.address, ipv6(3))
        for (index in 0..candidates.size) {
            @Expect(candidates[index].ordinal, index)
            @Expect(candidates[index].endpoint.port, 443)
        }
    }

    @TestCase
    func firstFamilyControlsPreferenceAndDuplicatesAreRemoved(): Unit {
        let plan = buildAttemptPlan([ipv4(1), ipv6(1), ipv4(1), ipv6(1), ipv4(2)], 80)
        let candidates = plan.candidates
        @Expect(candidates.size, 3)
        @Expect(candidates[0].endpoint.address.family, IpAddressFamily.Ipv4)
        @Expect(candidates[1].endpoint.address.family, IpAddressFamily.Ipv6)
        @Expect(candidates[2].endpoint.address, ipv4(2))
    }

    @TestCase
    func distinctIpv6ZonesAreNotDeduplicated(): Unit {
        let plan = buildAttemptPlan([ipv6(1, zone: Some("2")), ipv6(1, zone: Some("3"))], 443)
        @Expect(plan.candidates.size, 2)
    }

    @TestCase
    func rejectsEmptyCandidatesAndNegativeDelay(): Unit {
        var emptyRejected = false
        try {
            let _ = buildAttemptPlan(Array<IpAddress>(), 443)
        } catch (_: IllegalArgumentException) {
            emptyRejected = true
        }
        @Expect(emptyRejected)

        var delayRejected = false
        try {
            let _ = buildAttemptPlan([ipv4(1)], 443, attemptDelay: Duration.Zero - Duration.nanosecond)
        } catch (_: IllegalArgumentException) {
            delayRejected = true
        }
        @Expect(delayRejected)
    }
}
