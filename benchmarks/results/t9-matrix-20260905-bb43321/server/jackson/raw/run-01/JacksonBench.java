import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * 同环境 Jackson 基线基准：与 json4cj T9.1-T9.4 场景一一对应。
 *
 * 方法论（对齐 @Bench）：预热 1s → 测量 5s 分为 200 批 → μs/op = elapsed_ns / reps。
 * 序列化用 writeValueAsBytes（物化输出，与 json4cj encode+toString 对等）。
 * 反序列化用 mapper.readValue(bytes, Class)。
 *
 * T9.5 coverage cases (matrix expansion) follow the 22 legacy cases; unknown
 * fields are tolerated (FAIL_ON_UNKNOWN_PROPERTIES off) to match the Cangjie
 * libraries' generated-decoder behavior. Bytes/stream track (t9_b_*) mirrors
 * the three-library BytesBench suite; cjjson has no bytes API and is excluded.
 */
public class JacksonBench {

    private static Set<String> selectedCases = Collections.emptySet();

    // ---- 对应 json4cj PrimitiveBean ----
    static class PrimitiveBean {
        public byte i8;
        public short i16;
        public int i32;
        public long i64;
        public double f64;
        public boolean flag;
        public String text;
    }

    // ---- 对应 json4cj StringBean ----
    static class StringBean {
        public String s1 = ""; public String s2 = ""; public String s3 = ""; public String s4 = "";
        public String s5 = ""; public String s6 = ""; public String s7 = ""; public String s8 = "";
    }

    // ---- 对应 json4cj CollectionBean ----
    static class CollectionBean {
        public long[] intArray = new long[0];
        public String[] strArray = new String[0];
        public Map<String, Long> intMap = new LinkedHashMap<>();
        public Map<String, String> strMap = new LinkedHashMap<>();
    }

    // ---- 对应 json4cj NestedCollBean ----
    static class NestedCollBean {
        public Map<String, long[]> data = new LinkedHashMap<>();
    }

    // ---- 对应 json4cj FloatArrayBean ----
    static class FloatArrayBean {
        public double[] f64Array = new double[0];
    }

    // ---- 对应 json4cj DeepNested (4 层) ----
    static class Level3 { public String value; public long count; }
    static class Level2 { public String value; public Level3 level3; }
    static class Level1 { public String value; public Level2 level2; }
    static class DeepNested { public Level1 level1; }

    // ---- 对应 json4cj WideNested (20 字段混合) ----
    static class WideNested {
        public long f1; public String f2 = ""; public double f3; public boolean f4; public String f5 = "";
        public long f6; public String f7 = ""; public double f8; public boolean f9; public String f10 = "";
        public long f11; public String f12 = ""; public double f13; public boolean f14; public String f15 = "";
        public long f16; public String f17 = ""; public double f18; public boolean f19; public String f20 = "";
    }

    // ---- 对应 json4cj UltraWide (50 long 字段) ----
    static class UltraWide {
        public long f0,f1,f2,f3,f4,f5,f6,f7,f8,f9;
        public long f10,f11,f12,f13,f14,f15,f16,f17,f18,f19;
        public long f20,f21,f22,f23,f24,f25,f26,f27,f28,f29;
        public long f30,f31,f32,f33,f34,f35,f36,f37,f38,f39;
        public long f40,f41,f42,f43,f44,f45,f46,f47,f48,f49;
    }

    // ---- T9.5 coverage beans (matrix expansion) ----
    static class InnerBean {
        public long id;
        public String label;
        public long score;
    }

    static class OptionBean {
        public String name;
        public Long count;
        public InnerBean inner;
        public String tag;
    }

    static class EmptyBean {
        public long[] arr = new long[0];
        public Map<String, Long> m = new LinkedHashMap<>();
        public String[] strs = new String[0];
        public InnerBean inner;
    }

    static class ExtremeBean {
        public long a;
        public long b;
        public long c = -1;
        public long d;
        public long e = 1;
    }

    static class LargeDocItem {
        public long id;
        public String sku;
        public String name;
        public String desc;
        public long price;
        public long stock;
        public boolean active;
        public long score;
        public String cat;
        public long rank;
    }

    static class LargeDoc {
        public List<LargeDocItem> items = new ArrayList<>();
        public Map<String, Long> index = new LinkedHashMap<>();
    }

    static class MatrixBean {
        public List<long[]> grid = new ArrayList<>();
    }

    static final String SEPARATOR = "------------------------------------------------------------";
    static final int BENCH_BATCHES = 200;
    static final long WARMUP_NANOS = 1_000_000_000L;
    static final long MEASURE_NANOS = 5_000_000_000L;
    static long sink = 0;

    static long[] buildLongArray(int size) {
        long[] result = new long[size];
        for (int i = 0; i < size; i++) result[i] = i;
        return result;
    }

    static double[] buildDoubleArray(int size) {
        double[] result = new double[size];
        for (int i = 0; i < size; i++) result[i] = i * 3.14;
        return result;
    }

    static Map<String, Long> buildLongMap(int size) {
        Map<String, Long> result = new LinkedHashMap<>();
        for (int i = 0; i < size; i++) result.put("key" + i, (long) i);
        return result;
    }

    static String repeat(char value, int size) {
        char[] chars = new char[size];
        Arrays.fill(chars, value);
        return new String(chars);
    }

    public static void main(String[] args) throws Exception {
        selectedCases = new HashSet<>(Arrays.asList(args));
        ObjectMapper mapper = new ObjectMapper();
        mapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

        // ---- 构造数据 ----
        PrimitiveBean prim = new PrimitiveBean();
        prim.i8 = 1; prim.i16 = 2; prim.i32 = 3; prim.i64 = 4;
        prim.f64 = 3.14; prim.flag = true; prim.text = "hello";
        byte[] primBytes = mapper.writeValueAsBytes(prim);

        StringBean strShort = new StringBean();
        strShort.s1 = "abc123"; strShort.s2 = "name"; strShort.s3 = "value"; strShort.s4 = "test";
        strShort.s5 = "data"; strShort.s6 = "item"; strShort.s7 = "code"; strShort.s8 = "desc";

        String longBase = repeat('a', 1000);
        StringBean strLong = new StringBean();
        strLong.s1 = longBase; strLong.s2 = longBase; strLong.s3 = longBase; strLong.s4 = longBase;
        strLong.s5 = longBase; strLong.s6 = longBase; strLong.s7 = longBase; strLong.s8 = longBase;

        StringBean strEscape = new StringBean();
        strEscape.s1 = "line1\nline2"; strEscape.s2 = "tab\there"; strEscape.s3 = "quote\"q"; strEscape.s4 = "back\\slash";
        strEscape.s5 = "cr\rfeed"; strEscape.s6 = "mix\n\t\"\\"; strEscape.s7 = "plain"; strEscape.s8 = "end";

        StringBean strUnicode = new StringBean();
        strUnicode.s1 = "中文测试"; strUnicode.s2 = "🎉🎊emoji"; strUnicode.s3 = "日本語テスト"; strUnicode.s4 = "한국어";
        strUnicode.s5 = "Русский"; strUnicode.s6 = "مرحبا"; strUnicode.s7 = "Ελληνικά"; strUnicode.s8 = "ทดสอบ";

        long[] rawArr = buildLongArray(1000);
        byte[] rawArrBytes = mapper.writeValueAsBytes(rawArr);

        CollectionBean collSmallArr = new CollectionBean();
        collSmallArr.intArray = buildLongArray(10);

        CollectionBean collLargeArr = new CollectionBean();
        collLargeArr.intArray = rawArr;
        byte[] collLargeArrBytes = mapper.writeValueAsBytes(collLargeArr);

        CollectionBean collSmallMap = new CollectionBean();
        collSmallMap.intMap = buildLongMap(10);

        CollectionBean collLargeMap = new CollectionBean();
        collLargeMap.intMap = buildLongMap(100);
        byte[] collLargeMapBytes = mapper.writeValueAsBytes(collLargeMap);

        NestedCollBean nestedColl = new NestedCollBean();
        for (int i = 0; i < 10; i++) nestedColl.data.put("k" + i, buildLongArray(10));
        byte[] nestedCollBytes = mapper.writeValueAsBytes(nestedColl);

        FloatArrayBean collLargeFloatArr = new FloatArrayBean();
        collLargeFloatArr.f64Array = buildDoubleArray(1000);

        DeepNested deep = new DeepNested();
        deep.level1 = new Level1(); deep.level1.value = "L1";
        deep.level1.level2 = new Level2(); deep.level1.level2.value = "L2";
        deep.level1.level2.level3 = new Level3(); deep.level1.level2.level3.value = "L3";
        deep.level1.level2.level3.count = 99;
        byte[] deepBytes = mapper.writeValueAsBytes(deep);

        WideNested wide = new WideNested();
        wide.f1 = 1; wide.f3 = 3.14; wide.f4 = true; wide.f6 = 6; wide.f20 = "wide";
        byte[] wideBytes = mapper.writeValueAsBytes(wide);

        UltraWide ultra = new UltraWide();
        byte[] ultraBytes = mapper.writeValueAsBytes(ultra);

        // ---- T9.5 coverage fixtures ----
        InnerBean inner = new InnerBean();
        inner.id = 7; inner.label = "inner"; inner.score = 650;

        OptionBean optionMixed = new OptionBean();
        optionMixed.name = "matrix"; optionMixed.inner = inner;

        OptionBean optionFull = new OptionBean();
        optionFull.name = "matrix"; optionFull.count = 42L; optionFull.inner = inner; optionFull.tag = "full";
        byte[] optionBytes = mapper.writeValueAsBytes(optionFull);

        EmptyBean emptyBean = new EmptyBean();
        byte[] emptyBytes = mapper.writeValueAsBytes(emptyBean);

        ExtremeBean extBean = new ExtremeBean();
        extBean.a = Long.MAX_VALUE; extBean.b = Long.MIN_VALUE;
        byte[] extBytes = mapper.writeValueAsBytes(extBean);

        LargeDoc largeDoc = new LargeDoc();
        String desc64 = repeat('x', 64);
        for (int i = 0; i < 3000; i++) {
            LargeDocItem item = new LargeDocItem();
            item.id = i; item.sku = "SKU-" + i + "-MX"; item.name = "item-name-" + i;
            item.desc = "description-" + i + "-" + desc64;
            item.price = 1000 + i; item.stock = i % 500; item.active = (i % 2 == 0);
            item.score = 90 + (i % 10); item.cat = "cat-" + (i % 12); item.rank = i % 100;
            largeDoc.items.add(item);
        }
        for (int i = 0; i < 2000; i++) largeDoc.index.put("key" + i, (long) i);
        byte[] largeDocBytes = mapper.writeValueAsBytes(largeDoc);

        MatrixBean matrixBean = new MatrixBean();
        for (int i = 0; i < 50; i++) matrixBean.grid.add(buildLongArray(20));
        byte[] matrixBytes = mapper.writeValueAsBytes(matrixBean);

        String unknownPayload = "{\"intArray\":[1,2,3],\"strArray\":[\"a\"],\"intMap\":{\"k\":1},\"strMap\":{\"a\":\"b\"},\"x1\":1,\"x2\":\"text\",\"x3\":[1,2],\"x4\":{\"k\":1},\"x5\":true}";
        byte[] unknownBytes = unknownPayload.getBytes(StandardCharsets.UTF_8);

        String prettyWideJson = "{\n"
            + "  \"f1\": 1,\n"
            + "  \"f2\": \"\",\n"
            + "  \"f3\": 3.14,\n"
            + "  \"f4\": true,\n"
            + "  \"f5\": \"\",\n"
            + "  \"f6\": 6,\n"
            + "  \"f7\": \"\",\n"
            + "  \"f8\": 0.0,\n"
            + "  \"f9\": false,\n"
            + "  \"f10\": \"\",\n"
            + "  \"f11\": 0,\n"
            + "  \"f12\": \"\",\n"
            + "  \"f13\": 0.0,\n"
            + "  \"f14\": false,\n"
            + "  \"f15\": \"\",\n"
            + "  \"f16\": 0,\n"
            + "  \"f17\": \"\",\n"
            + "  \"f18\": 0.0,\n"
            + "  \"f19\": false,\n"
            + "  \"f20\": \"wide\"\n"
            + "}";
        byte[] prettyBytes = prettyWideJson.getBytes(StandardCharsets.UTF_8);

        System.out.println("=== Jackson T9 对齐基准 ===");
        System.out.printf("%-34s %10s %12s%n", "case", "median", "ops/ms");
        System.out.println(SEPARATOR);

        // T9.1
        bench("t9_1_1_primitiveSerialize",   () -> { try { sink = mapper.writeValueAsBytes(prim).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_1_2_primitiveDeserialize", () -> { try { sink = mapper.readValue(primBytes, PrimitiveBean.class).i64; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_1_3_primitiveRoundTrip",    () -> { try { sink = mapper.readValue(mapper.writeValueAsBytes(prim), PrimitiveBean.class).i64; } catch (Exception e) { throw new RuntimeException(e); } });

        // T9.2
        bench("t9_2_1_shortStringSerialize",  () -> { try { sink = mapper.writeValueAsBytes(strShort).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_2_2_longStringSerialize",   () -> { try { sink = mapper.writeValueAsBytes(strLong).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_2_3_escapeStringSerialize", () -> { try { sink = mapper.writeValueAsBytes(strEscape).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_2_4_unicodeStringSerialize", () -> { try { sink = mapper.writeValueAsBytes(strUnicode).length; } catch (Exception e) { throw new RuntimeException(e); } });

        // T9.3
        bench("t9_3_1_smallArraySerialize",   () -> { try { sink = mapper.writeValueAsBytes(collSmallArr).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_3_2_largeArraySerialize",   () -> { try { sink = mapper.writeValueAsBytes(collLargeArr).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_3_3_largeArrayDeserialize", () -> { try { sink = mapper.readValue(collLargeArrBytes, CollectionBean.class).intArray.length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_3_4_smallMapSerialize",     () -> { try { sink = mapper.writeValueAsBytes(collSmallMap).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_3_5_largeMapSerialize",     () -> { try { sink = mapper.writeValueAsBytes(collLargeMap).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_3_6_largeMapDeserialize",   () -> { try { sink = mapper.readValue(collLargeMapBytes, CollectionBean.class).intMap.size(); } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_3_7_nestedCollectionSerialize", () -> { try { sink = mapper.writeValueAsBytes(nestedColl).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_3_8_nestedCollectionDeserialize", () -> { try { sink = mapper.readValue(nestedCollBytes, NestedCollBean.class).data.size(); } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_3_9_largeFloat64ArraySerialize", () -> { try { sink = mapper.writeValueAsBytes(collLargeFloatArr).length; } catch (Exception e) { throw new RuntimeException(e); } });

        // T9.4
        bench("t9_4_1_deepNestedSerialize",   () -> { try { sink = mapper.writeValueAsBytes(deep).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_4_2_deepNestedDeserialize", () -> { try { sink = mapper.readValue(deepBytes, DeepNested.class).level1.level2.level3.count; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_4_3_wideSerialize",         () -> { try { sink = mapper.writeValueAsBytes(wide).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_4_4_wideDeserialize",       () -> { try { sink = mapper.readValue(wideBytes, WideNested.class).f1; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_4_5_ultraWideSerialize",    () -> { try { sink = mapper.writeValueAsBytes(ultra).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_4_6_ultraWideDeserialize",  () -> { try { sink = mapper.readValue(ultraBytes, UltraWide.class).f49; } catch (Exception e) { throw new RuntimeException(e); } });

        // T9.5 coverage (matrix expansion)
        bench("t9_5_1_optionSerialize", () -> { try { sink = mapper.writeValueAsBytes(optionMixed).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_2_optionDeserialize", () -> { try { OptionBean o = mapper.readValue(optionBytes, OptionBean.class); sink = (o.count == null) ? 0 : o.count; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_3_optionRoundTrip", () -> { try { OptionBean o = mapper.readValue(mapper.writeValueAsBytes(optionFull), OptionBean.class); sink = (o.count == null) ? 0 : o.count; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_4_emptyContainersSerialize", () -> { try { sink = mapper.writeValueAsBytes(emptyBean).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_5_emptyContainersDeserialize", () -> { try { sink = mapper.readValue(emptyBytes, EmptyBean.class).arr.length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_6_int64ExtremesSerialize", () -> { try { sink = mapper.writeValueAsBytes(extBean).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_7_int64ExtremesDeserialize", () -> { try { sink = mapper.readValue(extBytes, ExtremeBean.class).a; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_8_unknownFieldDeserialize", () -> { try { sink = mapper.readValue(unknownBytes, CollectionBean.class).intArray.length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_9_largeDocumentSerialize", () -> { try { sink = mapper.writeValueAsBytes(largeDoc).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_10_largeDocumentDeserialize", () -> { try { sink = mapper.readValue(largeDocBytes, LargeDoc.class).items.size(); } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_11_arrayOfArraySerialize", () -> { try { sink = mapper.writeValueAsBytes(matrixBean).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_12_arrayOfArrayDeserialize", () -> { try { sink = mapper.readValue(matrixBytes, MatrixBean.class).grid.size(); } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_5_13_prettyWideDeserialize", () -> { try { sink = mapper.readValue(prettyBytes, WideNested.class).f1; } catch (Exception e) { throw new RuntimeException(e); } });

        // bytes/stream track (three-library; cjjson has no bytes API and is excluded)
        bench("t9_b_1_bytesParsePrimitive", () -> { try { sink = mapper.readValue(primBytes, PrimitiveBean.class).i64; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_b_2_bytesParseLargeDoc", () -> { try { sink = mapper.readValue(largeDocBytes, LargeDoc.class).items.size(); } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_b_3_streamLargeDoc", () -> { try { sink = mapper.readValue(new ByteArrayInputStream(largeDocBytes), LargeDoc.class).items.size(); } catch (Exception e) { throw new RuntimeException(e); } });

        // Output materialization diagnostics: _bytes is comparable to Cangjie toBytes(),
        // while _string is comparable to Cangjie toString().
        bench("t9_1_1_primitiveSerialize_bytes", () -> { try { sink = mapper.writeValueAsBytes(prim).length; } catch (Exception e) { throw new RuntimeException(e); } });
        bench("t9_1_1_primitiveSerialize_string", () -> { try { sink = mapper.writeValueAsString(prim).length(); } catch (Exception e) { throw new RuntimeException(e); } });

        System.out.println(SEPARATOR);
        System.out.println("(sink=" + sink + " 防 DCE)");
    }

    /** 对齐 @Bench：预热 1s，测量 5s 分为 200 批，输出每批耗时的中位 μs/op。 */
    static void bench(String name, Runnable op) {
        if (!selectedCases.isEmpty() && !selectedCases.contains(name)) {
            return;
        }
        long warmEnd = System.nanoTime() + WARMUP_NANOS;
        while (System.nanoTime() < warmEnd) { op.run(); }

        double[] batchUsPerOp = new double[BENCH_BATCHES];
        long nanosPerBatch = MEASURE_NANOS / BENCH_BATCHES;
        for (int batch = 0; batch < BENCH_BATCHES; batch++) {
            long reps = 0;
            long start = System.nanoTime();
            long batchEnd = start + nanosPerBatch;
            do { op.run(); reps++; } while (System.nanoTime() < batchEnd);
            batchUsPerOp[batch] = (System.nanoTime() - start) / 1000.0 / reps;
        }
        Arrays.sort(batchUsPerOp);
        double medianUsPerOp = (batchUsPerOp[BENCH_BATCHES / 2 - 1] + batchUsPerOp[BENCH_BATCHES / 2]) / 2.0;
        System.out.printf("%-34s %8.3f us  %10.1f%n", name, medianUsPerOp, 1000.0 / medianUsPerOp);
    }
}
