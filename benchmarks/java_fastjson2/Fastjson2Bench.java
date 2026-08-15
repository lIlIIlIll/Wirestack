// Standalone comparison harness; not part of the Cangjie package.
import com.alibaba.fastjson2.JSON;
import com.alibaba.fastjson2.JSONReader;
import com.alibaba.fastjson2.JSONWriter;
import com.alibaba.fastjson2.TypeReference;
import com.alibaba.fastjson2.annotation.JSONField;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class Fastjson2Bench {
    private static final JSONWriter.Feature[] WRITE_FEATURES = {
        JSONWriter.Feature.FieldBased,
        JSONWriter.Feature.WriteNulls,
        JSONWriter.Feature.WriteBigDecimalAsPlain
    };
    private static final JSONWriter.Feature[] WRITE_FEATURES_WITH_PRETTY = {
        JSONWriter.Feature.FieldBased,
        JSONWriter.Feature.WriteNulls,
        JSONWriter.Feature.WriteBigDecimalAsPlain,
        JSONWriter.Feature.PrettyFormat
    };
    private static final JSONReader.Feature[] READ_FEATURES = {
        JSONReader.Feature.FieldBased
    };

    private static final String ADDRESS_JSON =
        "{\"street_name\":\"Nanshan Road\",\"zipcode\":518000}";
    private static final String PERSON_JSON =
        "{\"user_id\":42,\"name\":\"Lin\",\"age\":28,"
            + "\"tags\":[\"cangjie\",\"json\",\"reflect\"],"
            + "\"scores\":{\"math\":95,\"english\":88},"
            + "\"address\":" + ADDRESS_JSON + ",\"nick\":null}";
    private static final String PROFILE_BUNDLE_JSON =
        "{\"groups\":{\"ops\":["
            + "{\"profile_id\":7,\"alias\":\"ops\",\"level\":3},"
            + "{\"profile_id\":9,\"alias\":\"infra\",\"level\":4}"
            + "],\"platform\":[{\"profile_id\":11,\"alias\":\"platform\",\"level\":5}]},"
            + "\"featured\":null}";
    private static final String UINT64_ENVELOPE_JSON =
        "{\"id\":18446744073709551615,"
            + "\"shardIds\":[0,18446744073709551614,42],"
            + "\"quotas\":{\"burst\":18446744073709551613,\"steady\":42}}";
    private static final String TEMPORAL_STATS_JSON =
        "{\"createdAt\":\"2024-06-20T14:42:33+08:00\","
            + "\"totalEvents\":123456789012345678901234567890,"
            + "\"averageLatency\":12.375,"
            + "\"checkpoints\":[\"2024-06-20T14:42:33+08:00\",\"2024-06-20T15:12:33+08:00\"],"
            + "\"ratios\":{\"p50\":12.5,\"p99\":98.25}}";
    private static final String ESCAPED_UNICODE_STRING_JSON =
        "\"Cangjie JSON \\\"escape\\\" \\\\ slash / line\\n tab\\t unicode \\u4ed3\\u9889 \\u0394 \\u2713\"";
    private static final String UNORDERED_PERSON_JSON =
        "{\"nick\":null,"
            + "\"address\":{\"zipcode\":518000,\"street_name\":\"Nanshan Road\"},"
            + "\"scores\":{\"english\":88,\"math\":95},"
            + "\"tags\":[\"cangjie\",\"json\",\"reflect\"],"
            + "\"age\":28,"
            + "\"name\":\"Lin\","
            + "\"user_id\":42}";
    private static final String UNKNOWN_PERSON_JSON =
        "{\"user_id\":42,"
            + "\"unknownObject\":{\"left\":[1,2,3],\"right\":{\"enabled\":true}},"
            + "\"name\":\"Lin\","
            + "\"age\":28,"
            + "\"tags\":[\"cangjie\",\"json\",\"reflect\"],"
            + "\"scores\":{\"math\":95,\"english\":88},"
            + "\"address\":{\"street_name\":\"Nanshan Road\",\"zipcode\":518000,\"ignored\":true},"
            + "\"unknownArray\":[{\"x\":1},null,false],"
            + "\"nick\":null}";
    private static final String PRETTY_PERSON_JSON =
        "{\n"
            + "  \"user_id\": 42,\n"
            + "  \"name\": \"Lin\",\n"
            + "  \"age\": 28,\n"
            + "  \"tags\": [\n"
            + "    \"cangjie\",\n"
            + "    \"json\",\n"
            + "    \"reflect\"\n"
            + "  ],\n"
            + "  \"scores\": {\n"
            + "    \"math\": 95,\n"
            + "    \"english\": 88\n"
            + "  },\n"
            + "  \"address\": {\n"
            + "    \"street_name\": \"Nanshan Road\",\n"
            + "    \"zipcode\": 518000\n"
            + "  },\n"
            + "  \"nick\": null\n"
            + "}";
    private static final TypeReference<LinkedHashMap<String, Long>> STRING_LONG_MAP =
        new TypeReference<LinkedHashMap<String, Long>>() {};
    private static final TypeReference<List<Map<String, List<ProfileRecord>>>> DEEP_NESTED_PROFILES =
        new TypeReference<List<Map<String, List<ProfileRecord>>>>() {};

    private static volatile Object objectSink;

    private Fastjson2Bench() {}

    public static void main(String[] args) {
        Config config = Config.parse(args);
        Fixture fixture = new Fixture();
        validateWireShape(fixture);

        List<BenchCase> cases = Arrays.asList(
            new BenchCase("ast-parse-person", () -> objectSink = JSON.parse(PERSON_JSON, READ_FEATURES)),
            new BenchCase("ast-stringify-person", () -> objectSink = JSON.toJSONString(fixture.personAst)),

            new BenchCase("string-encode-address", () -> objectSink = JSON.toJSONString(fixture.address, WRITE_FEATURES)),
            new BenchCase("string-decode-address", () -> objectSink = JSON.parseObject(ADDRESS_JSON, Address.class, READ_FEATURES)),
            new BenchCase("string-encode-person", () -> objectSink = JSON.toJSONString(fixture.person, WRITE_FEATURES)),
            new BenchCase("string-decode-person", () -> objectSink = JSON.parseObject(PERSON_JSON, Person.class, READ_FEATURES)),
            new BenchCase("string-encode-profile-bundle", () -> objectSink = JSON.toJSONString(fixture.profileBundle, WRITE_FEATURES)),
            new BenchCase("string-decode-profile-bundle", () -> objectSink = JSON.parseObject(PROFILE_BUNDLE_JSON, ProfileBundle.class, READ_FEATURES)),
            new BenchCase("string-encode-uint64-envelope", () -> objectSink = JSON.toJSONString(fixture.uint64Envelope, WRITE_FEATURES)),
            new BenchCase("string-decode-uint64-envelope", () -> objectSink = JSON.parseObject(UINT64_ENVELOPE_JSON, UInt64Envelope.class, READ_FEATURES)),
            new BenchCase("string-encode-temporal-stats", () -> objectSink = JSON.toJSONString(fixture.temporalStats, WRITE_FEATURES)),
            new BenchCase("string-decode-temporal-stats", () -> objectSink = JSON.parseObject(TEMPORAL_STATS_JSON, TemporalStats.class, READ_FEATURES)),
            new BenchCase("string-encode-pretty-person", () -> objectSink = JSON.toJSONString(fixture.person, WRITE_FEATURES_WITH_PRETTY)),

            new BenchCase("bytes-encode-address", () -> objectSink = JSON.toJSONBytes(fixture.address, WRITE_FEATURES)),
            new BenchCase("bytes-decode-address", () -> objectSink = JSON.parseObject(fixture.addressBytes, Address.class, READ_FEATURES)),
            new BenchCase("bytes-encode-person", () -> objectSink = JSON.toJSONBytes(fixture.person, WRITE_FEATURES)),
            new BenchCase("bytes-decode-person", () -> objectSink = JSON.parseObject(fixture.personBytes, Person.class, READ_FEATURES)),
            new BenchCase("bytes-encode-profile-bundle", () -> objectSink = JSON.toJSONBytes(fixture.profileBundle, WRITE_FEATURES)),
            new BenchCase("bytes-decode-profile-bundle", () -> objectSink = JSON.parseObject(fixture.profileBundleBytes, ProfileBundle.class, READ_FEATURES)),
            new BenchCase("bytes-encode-uint64-envelope", () -> objectSink = JSON.toJSONBytes(fixture.uint64Envelope, WRITE_FEATURES)),
            new BenchCase("bytes-decode-uint64-envelope", () -> objectSink = JSON.parseObject(fixture.uint64EnvelopeBytes, UInt64Envelope.class, READ_FEATURES)),
            new BenchCase("bytes-encode-temporal-stats", () -> objectSink = JSON.toJSONBytes(fixture.temporalStats, WRITE_FEATURES)),
            new BenchCase("bytes-decode-temporal-stats", () -> objectSink = JSON.parseObject(fixture.temporalStatsBytes, TemporalStats.class, READ_FEATURES)),

            new BenchCase("string-encode-escaped-unicode-string", () -> objectSink = JSON.toJSONString(fixture.escapedUnicodeText)),
            new BenchCase("string-decode-escaped-unicode-string", () -> objectSink = JSON.parseObject(fixture.escapedUnicodeJson, String.class)),
            new BenchCase("bytes-encode-escaped-unicode-string", () -> objectSink = JSON.toJSONBytes(fixture.escapedUnicodeText)),
            new BenchCase("bytes-decode-escaped-unicode-string", () -> objectSink = JSON.parseObject(fixture.escapedUnicodeBytes, String.class)),

            new BenchCase("string-encode-large-profile-array", () -> objectSink = JSON.toJSONString(fixture.largeProfiles, WRITE_FEATURES)),
            new BenchCase("string-decode-large-profile-array", () -> objectSink = JSON.parseArray(fixture.largeProfilesJson, ProfileRecord.class, READ_FEATURES)),
            new BenchCase("string-encode-large-int64-map", () -> objectSink = JSON.toJSONString(fixture.largeInt64Map, WRITE_FEATURES)),
            new BenchCase("string-decode-large-int64-map", () -> objectSink = JSON.parseObject(fixture.largeInt64MapJson, STRING_LONG_MAP, READ_FEATURES)),
            new BenchCase("string-encode-deep-nested-profiles", () -> objectSink = JSON.toJSONString(fixture.deepNestedProfiles, WRITE_FEATURES)),
            new BenchCase("string-decode-deep-nested-profiles", () -> objectSink = JSON.parseObject(fixture.deepNestedProfilesJson, DEEP_NESTED_PROFILES, READ_FEATURES)),

            new BenchCase("string-decode-unordered-person", () -> objectSink = JSON.parseObject(UNORDERED_PERSON_JSON, Person.class, READ_FEATURES)),
            new BenchCase("string-decode-unknown-person", () -> objectSink = JSON.parseObject(UNKNOWN_PERSON_JSON, Person.class, READ_FEATURES)),
            new BenchCase("string-decode-pretty-person", () -> objectSink = JSON.parseObject(PRETTY_PERSON_JSON, Person.class, READ_FEATURES))
        );

        System.out.println("case,medianNs");
        for (BenchCase benchCase : cases) {
            long median = measureMedianNs(benchCase, config);
            System.out.println(benchCase.name + "," + median);
        }
    }

    private static long measureMedianNs(BenchCase benchCase, Config config) {
        for (int batch = 0; batch < config.warmupBatches; batch++) {
            runIterations(benchCase, config.iterations);
        }

        long[] batchNs = new long[config.batches];
        for (int batch = 0; batch < config.batches; batch++) {
            long start = System.nanoTime();
            runIterations(benchCase, config.iterations);
            long elapsed = System.nanoTime() - start;
            batchNs[batch] = elapsed / config.iterations;
        }
        Arrays.sort(batchNs);
        return batchNs[batchNs.length / 2];
    }

    private static void runIterations(BenchCase benchCase, int iterations) {
        for (int i = 0; i < iterations; i++) {
            benchCase.action.run();
        }
    }

    private static void validateWireShape(Fixture fixture) {
        assertEquals("address street", "Nanshan Road", JSON.parseObject(ADDRESS_JSON, Address.class, READ_FEATURES).street);
        assertEquals("person id", 42L, JSON.parseObject(PERSON_JSON, Person.class, READ_FEATURES).id);

        String personText = JSON.toJSONString(fixture.person, WRITE_FEATURES);
        assertContains("person field name", personText, "\"user_id\":42");
        assertContains("address field name", personText, "\"street_name\":\"Nanshan Road\"");
        assertContains("included null nick", personText, "\"nick\":null");
        assertNotContains("ignored field", personText, "ignored");

        String bundleText = JSON.toJSONString(fixture.profileBundle, WRITE_FEATURES);
        assertContains("profile field name", bundleText, "\"profile_id\":11");
        assertContains("included null featured", bundleText, "\"featured\":null");

        UInt64Envelope uint64Envelope = JSON.parseObject(UINT64_ENVELOPE_JSON, UInt64Envelope.class, READ_FEATURES);
        assertEquals("uint64 id", new BigInteger("18446744073709551615"), uint64Envelope.id);
        assertEquals("uint64 shard", new BigInteger("18446744073709551614"), uint64Envelope.shardIds.get(1));
        assertEquals("uint64 quota", new BigInteger("18446744073709551613"), uint64Envelope.quotas.get("burst"));
        String uint64Text = JSON.toJSONString(fixture.uint64Envelope, WRITE_FEATURES);
        assertContains("uint64 bare id", uint64Text, "\"id\":18446744073709551615");
        assertContains("uint64 bare array", uint64Text, "\"shardIds\":[0,18446744073709551614,42]");
        assertContains("uint64 bare map", uint64Text, "\"burst\":18446744073709551613");
        assertNotContains("uint64 quoted", uint64Text, "\"18446744073709551615\"");

        TemporalStats temporalStats = JSON.parseObject(TEMPORAL_STATS_JSON, TemporalStats.class, READ_FEATURES);
        assertEquals("datetime string", "2024-06-20T14:42:33+08:00", temporalStats.createdAt);
        assertEquals("big integer", new BigInteger("123456789012345678901234567890"), temporalStats.totalEvents);
        assertBigDecimal("decimal", new BigDecimal("12.375"), temporalStats.averageLatency);
        assertBigDecimal("decimal map", new BigDecimal("98.25"), temporalStats.ratios.get("p99"));
        String temporalText = JSON.toJSONString(fixture.temporalStats, WRITE_FEATURES);
        assertContains("bigint bare", temporalText, "\"totalEvents\":123456789012345678901234567890");
        assertContains("decimal bare", temporalText, "\"averageLatency\":12.375");
        assertNotContains("bigint quoted", temporalText, "\"123456789012345678901234567890\"");

        assertEquals("escaped unicode", fixture.escapedUnicodeText, JSON.parseObject(fixture.escapedUnicodeJson, String.class));
        assertEquals("unordered person id", 42L, JSON.parseObject(UNORDERED_PERSON_JSON, Person.class, READ_FEATURES).id);
        assertEquals("unknown person id", 42L, JSON.parseObject(UNKNOWN_PERSON_JSON, Person.class, READ_FEATURES).id);
        assertEquals("pretty person id", 42L, JSON.parseObject(PRETTY_PERSON_JSON, Person.class, READ_FEATURES).id);
        assertEquals("large profile count", 64, JSON.parseArray(fixture.largeProfilesJson, ProfileRecord.class, READ_FEATURES).size());
        assertEquals(
            "large int64 map",
            Long.valueOf(547L),
            JSON.parseObject(fixture.largeInt64MapJson, STRING_LONG_MAP, READ_FEATURES).get("metric_32")
        );
        assertEquals(
            "deep nested profile count",
            8,
            JSON.parseObject(fixture.deepNestedProfilesJson, DEEP_NESTED_PROFILES, READ_FEATURES).size()
        );
    }

    private static void assertEquals(String label, Object expected, Object actual) {
        if (!expected.equals(actual)) {
            throw new IllegalStateException(label + ": expected " + expected + ", got " + actual);
        }
    }

    private static void assertBigDecimal(String label, BigDecimal expected, BigDecimal actual) {
        if (expected.compareTo(actual) != 0) {
            throw new IllegalStateException(label + ": expected " + expected + ", got " + actual);
        }
    }

    private static void assertContains(String label, String text, String needle) {
        if (!text.contains(needle)) {
            throw new IllegalStateException(label + ": missing `" + needle + "` in " + text);
        }
    }

    private static void assertNotContains(String label, String text, String needle) {
        if (text.contains(needle)) {
            throw new IllegalStateException(label + ": unexpected `" + needle + "` in " + text);
        }
    }

    private static Address sampleAddress() {
        return new Address("Nanshan Road", 518000);
    }

    private static Person samplePerson() {
        LinkedHashMap<String, Long> scores = new LinkedHashMap<>();
        scores.put("math", 95L);
        scores.put("english", 88L);
        return new Person(
            42L,
            "Lin",
            28,
            new ArrayList<>(Arrays.asList("cangjie", "json", "reflect")),
            scores,
            sampleAddress(),
            null
        );
    }

    private static ProfileRecord profile(long id, String alias, int level) {
        return new ProfileRecord(id, alias, level);
    }

    private static ProfileBundle sampleProfileBundleForBench() {
        LinkedHashMap<String, List<ProfileRecord>> groups = new LinkedHashMap<>();
        groups.put("ops", new ArrayList<>(Arrays.asList(profile(7, "ops", 3), profile(9, "infra", 4))));
        groups.put("platform", new ArrayList<>(Arrays.asList(profile(11, "platform", 5))));
        return new ProfileBundle(groups, null);
    }

    private static UInt64Envelope sampleUInt64Envelope() {
        LinkedHashMap<String, BigInteger> quotas = new LinkedHashMap<>();
        quotas.put("burst", new BigInteger("18446744073709551613"));
        quotas.put("steady", BigInteger.valueOf(42));
        return new UInt64Envelope(
            new BigInteger("18446744073709551615"),
            new ArrayList<>(Arrays.asList(
                BigInteger.ZERO,
                new BigInteger("18446744073709551614"),
                BigInteger.valueOf(42)
            )),
            quotas
        );
    }

    private static TemporalStats sampleTemporalStats() {
        LinkedHashMap<String, BigDecimal> ratios = new LinkedHashMap<>();
        ratios.put("p50", new BigDecimal("12.5"));
        ratios.put("p99", new BigDecimal("98.25"));
        return new TemporalStats(
            "2024-06-20T14:42:33+08:00",
            new BigInteger("123456789012345678901234567890"),
            new BigDecimal("12.375"),
            new ArrayList<>(Arrays.asList("2024-06-20T14:42:33+08:00", "2024-06-20T15:12:33+08:00")),
            ratios
        );
    }

    private static List<ProfileRecord> sampleLargeProfiles(int count) {
        List<ProfileRecord> profiles = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            profiles.add(profile(10_000L + i, "alias-" + (i % 16) + "-json-escape", i % 10));
        }
        return profiles;
    }

    private static LinkedHashMap<String, Long> sampleLargeInt64Map(int count) {
        LinkedHashMap<String, Long> values = new LinkedHashMap<>(count);
        for (int i = 0; i < count; i++) {
            values.put("metric_" + i, i * 17L + 3L);
        }
        return values;
    }

    private static List<Map<String, List<ProfileRecord>>> sampleDeepNestedProfiles(int groupCount, int recordCount) {
        List<Map<String, List<ProfileRecord>>> nested = new ArrayList<>(groupCount);
        for (int groupIndex = 0; groupIndex < groupCount; groupIndex++) {
            LinkedHashMap<String, List<ProfileRecord>> group = new LinkedHashMap<>();
            List<ProfileRecord> profiles = new ArrayList<>(recordCount);
            for (int recordIndex = 0; recordIndex < recordCount; recordIndex++) {
                profiles.add(profile(
                    groupIndex * 100L + recordIndex,
                    "group-" + groupIndex + "-profile-" + recordIndex,
                    (groupIndex + recordIndex) % 10
                ));
            }
            group.put("group_" + groupIndex, profiles);
            nested.add(group);
        }
        return nested;
    }

    private static final class Fixture {
        final Address address = sampleAddress();
        final Person person = samplePerson();
        final ProfileBundle profileBundle = sampleProfileBundleForBench();
        final UInt64Envelope uint64Envelope = sampleUInt64Envelope();
        final TemporalStats temporalStats = sampleTemporalStats();
        final String escapedUnicodeText = JSON.parseObject(ESCAPED_UNICODE_STRING_JSON, String.class);
        final List<ProfileRecord> largeProfiles = sampleLargeProfiles(64);
        final LinkedHashMap<String, Long> largeInt64Map = sampleLargeInt64Map(64);
        final List<Map<String, List<ProfileRecord>>> deepNestedProfiles = sampleDeepNestedProfiles(8, 4);
        final Object personAst = JSON.parse(PERSON_JSON, READ_FEATURES);
        final String escapedUnicodeJson = JSON.toJSONString(escapedUnicodeText);
        final String largeProfilesJson = JSON.toJSONString(largeProfiles, WRITE_FEATURES);
        final String largeInt64MapJson = JSON.toJSONString(largeInt64Map, WRITE_FEATURES);
        final String deepNestedProfilesJson = JSON.toJSONString(deepNestedProfiles, WRITE_FEATURES);
        final byte[] addressBytes = ADDRESS_JSON.getBytes(StandardCharsets.UTF_8);
        final byte[] personBytes = PERSON_JSON.getBytes(StandardCharsets.UTF_8);
        final byte[] profileBundleBytes = PROFILE_BUNDLE_JSON.getBytes(StandardCharsets.UTF_8);
        final byte[] uint64EnvelopeBytes = UINT64_ENVELOPE_JSON.getBytes(StandardCharsets.UTF_8);
        final byte[] temporalStatsBytes = TEMPORAL_STATS_JSON.getBytes(StandardCharsets.UTF_8);
        final byte[] escapedUnicodeBytes = escapedUnicodeJson.getBytes(StandardCharsets.UTF_8);
    }

    private static final class Config {
        final int iterations;
        final int warmupBatches;
        final int batches;

        Config(int iterations, int warmupBatches, int batches) {
            this.iterations = iterations;
            this.warmupBatches = warmupBatches;
            this.batches = batches;
        }

        static Config parse(String[] args) {
            int iterations = 10_000;
            int warmupBatches = 3;
            int batches = 11;
            for (int i = 0; i < args.length; i++) {
                switch (args[i]) {
                    case "--quick":
                        iterations = 1_000;
                        warmupBatches = 1;
                        batches = 5;
                        break;
                    case "--iterations":
                        iterations = parsePositive(args, ++i, "--iterations");
                        break;
                    case "--warmup":
                        warmupBatches = parsePositive(args, ++i, "--warmup");
                        break;
                    case "--batches":
                        batches = parsePositive(args, ++i, "--batches");
                        break;
                    case "--help":
                    case "-h":
                        printUsageAndExit();
                        break;
                    default:
                        throw new IllegalArgumentException("Unknown argument: " + args[i]);
                }
            }
            return new Config(iterations, warmupBatches, batches);
        }

        private static int parsePositive(String[] args, int index, String name) {
            if (index >= args.length) {
                throw new IllegalArgumentException(name + " requires a value");
            }
            int value = Integer.parseInt(args[index]);
            if (value <= 0) {
                throw new IllegalArgumentException(name + " must be positive");
            }
            return value;
        }

        private static void printUsageAndExit() {
            System.out.println("Usage: ./run.sh [--quick] [--iterations N] [--warmup N] [--batches N]");
            System.exit(0);
        }
    }

    private static final class BenchCase {
        final String name;
        final BenchAction action;

        BenchCase(String name, BenchAction action) {
            this.name = name;
            this.action = action;
        }
    }

    @FunctionalInterface
    private interface BenchAction {
        void run();
    }

    public static final class Address {
        @JSONField(name = "street_name", ordinal = 1)
        public String street;
        @JSONField(ordinal = 2)
        public long zipcode;

        public Address() {}

        public Address(String street, long zipcode) {
            this.street = street;
            this.zipcode = zipcode;
        }
    }

    public static final class Person {
        @JSONField(name = "user_id", ordinal = 1)
        public long id;
        @JSONField(ordinal = 2)
        public String name;
        @JSONField(ordinal = 3)
        public int age;
        @JSONField(ordinal = 4)
        public List<String> tags;
        @JSONField(ordinal = 5)
        public Map<String, Long> scores;
        @JSONField(ordinal = 6)
        public Address address;
        @JSONField(ordinal = 7)
        public String nick;
        @JSONField(serialize = false, deserialize = false)
        public String ignored = "should-not-appear";

        public Person() {}

        public Person(long id, String name, int age, List<String> tags, Map<String, Long> scores, Address address, String nick) {
            this.id = id;
            this.name = name;
            this.age = age;
            this.tags = tags;
            this.scores = scores;
            this.address = address;
            this.nick = nick;
        }
    }

    public static final class ProfileRecord {
        @JSONField(name = "profile_id", ordinal = 1)
        public long id;
        @JSONField(ordinal = 2)
        public String alias;
        @JSONField(ordinal = 3)
        public int level;

        public ProfileRecord() {}

        public ProfileRecord(long id, String alias, int level) {
            this.id = id;
            this.alias = alias;
            this.level = level;
        }
    }

    public static final class ProfileBundle {
        @JSONField(ordinal = 1)
        public Map<String, List<ProfileRecord>> groups;
        @JSONField(ordinal = 2)
        public ProfileRecord featured;

        public ProfileBundle() {}

        public ProfileBundle(Map<String, List<ProfileRecord>> groups, ProfileRecord featured) {
            this.groups = groups;
            this.featured = featured;
        }
    }

    public static final class UInt64Envelope {
        @JSONField(ordinal = 1)
        public BigInteger id;
        @JSONField(ordinal = 2)
        public List<BigInteger> shardIds;
        @JSONField(ordinal = 3)
        public Map<String, BigInteger> quotas;

        public UInt64Envelope() {}

        public UInt64Envelope(BigInteger id, List<BigInteger> shardIds, Map<String, BigInteger> quotas) {
            this.id = id;
            this.shardIds = shardIds;
            this.quotas = quotas;
        }
    }

    public static final class TemporalStats {
        @JSONField(ordinal = 1)
        public String createdAt;
        @JSONField(ordinal = 2)
        public BigInteger totalEvents;
        @JSONField(ordinal = 3)
        public BigDecimal averageLatency;
        @JSONField(ordinal = 4)
        public List<String> checkpoints;
        @JSONField(ordinal = 5)
        public Map<String, BigDecimal> ratios;

        public TemporalStats() {}

        public TemporalStats(
            String createdAt,
            BigInteger totalEvents,
            BigDecimal averageLatency,
            List<String> checkpoints,
            Map<String, BigDecimal> ratios
        ) {
            this.createdAt = createdAt;
            this.totalEvents = totalEvents;
            this.averageLatency = averageLatency;
            this.checkpoints = checkpoints;
            this.ratios = ratios;
        }
    }
}
