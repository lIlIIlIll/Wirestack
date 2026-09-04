package jmh;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.Warmup;

import java.io.ByteArrayInputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * JMH 版 Jackson 基线（与 JacksonBench.java 手写计时同负载）。
 *
 * 目的：消除手写循环计时缺少 JMH 防护（OSR/去优化/死代码消除）带来的系统性偏差。
 * 每个 @Benchmark 与 JacksonBench 的 bench("t9_*", ...) 注册一一对应；
 * 输出经 scripts/run_t9_jmh.py 转换成与 run_t9_jackson.py 相同的
 * `t9_* <x> us` 行契约，供同一 summarize 流水线使用。
 * JMH 要求具名包，故 bean/fixture 在此自包含（与 JacksonBench 逐字对应）。
 */
@State(Scope.Thread)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MICROSECONDS)
@Warmup(iterations = 2, time = 1)
@Measurement(iterations = 5, time = 1)
@Fork(1)
public class JacksonBenchJMH {

    // ---- beans（与 JacksonBench 逐字对应） ----

    static class PrimitiveBean {
        public byte i8;
        public short i16;
        public int i32;
        public long i64;
        public double f64;
        public boolean flag;
        public String text;
    }

    static class StringBean {
        public String s1 = ""; public String s2 = ""; public String s3 = ""; public String s4 = "";
        public String s5 = ""; public String s6 = ""; public String s7 = ""; public String s8 = "";
    }

    static class CollectionBean {
        public long[] intArray = new long[0];
        public String[] strArray = new String[0];
        public Map<String, Long> intMap = new LinkedHashMap<>();
        public Map<String, String> strMap = new LinkedHashMap<>();
    }

    static class NestedCollBean {
        public Map<String, long[]> data = new LinkedHashMap<>();
    }

    static class FloatArrayBean {
        public double[] f64Array = new double[0];
    }

    static class Level3 { public String value; public long count; }
    static class Level2 { public String value; public Level3 level3; }
    static class Level1 { public String value; public Level2 level2; }
    static class DeepNested { public Level1 level1; }

    static class WideNested {
        public long f1; public String f2 = ""; public double f3; public boolean f4; public String f5 = "";
        public long f6; public String f7 = ""; public double f8; public boolean f9; public String f10 = "";
        public long f11; public String f12 = ""; public double f13; public boolean f14; public String f15 = "";
        public long f16; public String f17 = ""; public double f18; public boolean f19; public String f20 = "";
    }

    static class UltraWide {
        public long f0,f1,f2,f3,f4,f5,f6,f7,f8,f9;
        public long f10,f11,f12,f13,f14,f15,f16,f17,f18,f19;
        public long f20,f21,f22,f23,f24,f25,f26,f27,f28,f29;
        public long f30,f31,f32,f33,f34,f35,f36,f37,f38,f39;
        public long f40,f41,f42,f43,f44,f45,f46,f47,f48,f49;
    }

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

    // ---- fixtures ----

    private ObjectMapper mapper;

    private PrimitiveBean prim;
    private byte[] primBytes;
    private StringBean strShort;
    private StringBean strLong;
    private StringBean strEscape;
    private StringBean strUnicode;
    private CollectionBean collSmallArr;
    private CollectionBean collLargeArr;
    private byte[] collLargeArrBytes;
    private CollectionBean collSmallMap;
    private CollectionBean collLargeMap;
    private byte[] collLargeMapBytes;
    private NestedCollBean nestedColl;
    private byte[] nestedCollBytes;
    private FloatArrayBean collLargeFloatArr;
    private DeepNested deep;
    private byte[] deepBytes;
    private WideNested wide;
    private byte[] wideBytes;
    private UltraWide ultra;
    private byte[] ultraBytes;

    private OptionBean optionMixed;
    private OptionBean optionFull;
    private byte[] optionBytes;
    private EmptyBean emptyBean;
    private byte[] emptyBytes;
    private ExtremeBean extBean;
    private byte[] extBytes;
    private LargeDoc largeDoc;
    private byte[] largeDocBytes;
    private MatrixBean matrixBean;
    private byte[] matrixBytes;
    private byte[] unknownBytes;
    private byte[] prettyBytes;

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

    @Setup
    public void setup() throws Exception {
        mapper = new ObjectMapper();
        mapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

        prim = new PrimitiveBean();
        prim.i8 = 1; prim.i16 = 2; prim.i32 = 3; prim.i64 = 4;
        prim.f64 = 3.14; prim.flag = true; prim.text = "hello";
        primBytes = mapper.writeValueAsBytes(prim);

        strShort = new StringBean();
        strShort.s1 = "abc123"; strShort.s2 = "name"; strShort.s3 = "value"; strShort.s4 = "test";
        strShort.s5 = "data"; strShort.s6 = "item"; strShort.s7 = "code"; strShort.s8 = "desc";

        String longBase = repeat('a', 1000);
        strLong = new StringBean();
        strLong.s1 = longBase; strLong.s2 = longBase; strLong.s3 = longBase; strLong.s4 = longBase;
        strLong.s5 = longBase; strLong.s6 = longBase; strLong.s7 = longBase; strLong.s8 = longBase;

        strEscape = new StringBean();
        strEscape.s1 = "line1\nline2"; strEscape.s2 = "tab\there"; strEscape.s3 = "quote\"q"; strEscape.s4 = "back\\slash";
        strEscape.s5 = "cr\rfeed"; strEscape.s6 = "mix\n\t\"\\"; strEscape.s7 = "plain"; strEscape.s8 = "end";

        strUnicode = new StringBean();
        strUnicode.s1 = "中文测试"; strUnicode.s2 = "🎉🎊emoji"; strUnicode.s3 = "日本語テスト"; strUnicode.s4 = "한국어";
        strUnicode.s5 = "Русский"; strUnicode.s6 = "مرحبا"; strUnicode.s7 = "Ελληνικά"; strUnicode.s8 = "ทดสอบ";

        collSmallArr = new CollectionBean();
        collSmallArr.intArray = buildLongArray(10);

        collLargeArr = new CollectionBean();
        collLargeArr.intArray = buildLongArray(1000);
        collLargeArrBytes = mapper.writeValueAsBytes(collLargeArr);

        collSmallMap = new CollectionBean();
        collSmallMap.intMap = buildLongMap(10);

        collLargeMap = new CollectionBean();
        collLargeMap.intMap = buildLongMap(100);
        collLargeMapBytes = mapper.writeValueAsBytes(collLargeMap);

        nestedColl = new NestedCollBean();
        for (int i = 0; i < 10; i++) nestedColl.data.put("k" + i, buildLongArray(10));
        nestedCollBytes = mapper.writeValueAsBytes(nestedColl);

        collLargeFloatArr = new FloatArrayBean();
        collLargeFloatArr.f64Array = buildDoubleArray(1000);

        deep = new DeepNested();
        deep.level1 = new Level1(); deep.level1.value = "L1";
        deep.level1.level2 = new Level2(); deep.level1.level2.value = "L2";
        deep.level1.level2.level3 = new Level3(); deep.level1.level2.level3.value = "L3";
        deep.level1.level2.level3.count = 99;
        deepBytes = mapper.writeValueAsBytes(deep);

        wide = new WideNested();
        wide.f1 = 1; wide.f3 = 3.14; wide.f4 = true; wide.f6 = 6; wide.f20 = "wide";
        wideBytes = mapper.writeValueAsBytes(wide);

        ultra = new UltraWide();
        ultraBytes = mapper.writeValueAsBytes(ultra);

        InnerBean inner = new InnerBean();
        inner.id = 7; inner.label = "inner"; inner.score = 650;

        optionMixed = new OptionBean();
        optionMixed.name = "matrix"; optionMixed.inner = inner;

        optionFull = new OptionBean();
        optionFull.name = "matrix"; optionFull.count = 42L; optionFull.inner = inner; optionFull.tag = "full";
        optionBytes = mapper.writeValueAsBytes(optionFull);

        emptyBean = new EmptyBean();
        emptyBytes = mapper.writeValueAsBytes(emptyBean);

        extBean = new ExtremeBean();
        extBean.a = Long.MAX_VALUE; extBean.b = Long.MIN_VALUE;
        extBytes = mapper.writeValueAsBytes(extBean);

        largeDoc = new LargeDoc();
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
        largeDocBytes = mapper.writeValueAsBytes(largeDoc);

        matrixBean = new MatrixBean();
        for (int i = 0; i < 50; i++) matrixBean.grid.add(buildLongArray(20));
        matrixBytes = mapper.writeValueAsBytes(matrixBean);

        String unknownPayload = "{\"intArray\":[1,2,3],\"strArray\":[\"a\"],\"intMap\":{\"k\":1},\"strMap\":{\"a\":\"b\"},\"x1\":1,\"x2\":\"text\",\"x3\":[1,2],\"x4\":{\"k\":1},\"x5\":true}";
        unknownBytes = unknownPayload.getBytes(java.nio.charset.StandardCharsets.UTF_8);

        StringBuilder pretty = new StringBuilder("{\n");
        pretty.append("  \"f1\": 1,\n");
        pretty.append("  \"f2\": \"\",\n");
        pretty.append("  \"f3\": 3.14,\n");
        pretty.append("  \"f4\": true,\n");
        pretty.append("  \"f5\": \"\",\n");
        pretty.append("  \"f6\": 6,\n");
        pretty.append("  \"f7\": \"\",\n");
        pretty.append("  \"f8\": 0.0,\n");
        pretty.append("  \"f9\": false,\n");
        pretty.append("  \"f10\": \"\",\n");
        pretty.append("  \"f11\": 0,\n");
        pretty.append("  \"f12\": \"\",\n");
        pretty.append("  \"f13\": 0.0,\n");
        pretty.append("  \"f14\": false,\n");
        pretty.append("  \"f15\": \"\",\n");
        pretty.append("  \"f16\": 0,\n");
        pretty.append("  \"f17\": \"\",\n");
        pretty.append("  \"f18\": 0.0,\n");
        pretty.append("  \"f19\": false,\n");
        pretty.append("  \"f20\": \"wide\"\n");
        pretty.append("}");
        prettyBytes = pretty.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
    }

    // ---- T9.1-T9.4 legacy (22) ----

    @Benchmark public long t9_1_1_primitiveSerialize() throws Exception { return mapper.writeValueAsBytes(prim).length; }
    @Benchmark public long t9_1_2_primitiveDeserialize() throws Exception { return mapper.readValue(primBytes, PrimitiveBean.class).i64; }
    @Benchmark public long t9_1_3_primitiveRoundTrip() throws Exception { return mapper.readValue(mapper.writeValueAsBytes(prim), PrimitiveBean.class).i64; }

    @Benchmark public long t9_2_1_shortStringSerialize() throws Exception { return mapper.writeValueAsBytes(strShort).length; }
    @Benchmark public long t9_2_2_longStringSerialize() throws Exception { return mapper.writeValueAsBytes(strLong).length; }
    @Benchmark public long t9_2_3_escapeStringSerialize() throws Exception { return mapper.writeValueAsBytes(strEscape).length; }
    @Benchmark public long t9_2_4_unicodeStringSerialize() throws Exception { return mapper.writeValueAsBytes(strUnicode).length; }

    @Benchmark public long t9_3_1_smallArraySerialize() throws Exception { return mapper.writeValueAsBytes(collSmallArr).length; }
    @Benchmark public long t9_3_2_largeArraySerialize() throws Exception { return mapper.writeValueAsBytes(collLargeArr).length; }
    @Benchmark public long t9_3_3_largeArrayDeserialize() throws Exception { return mapper.readValue(collLargeArrBytes, CollectionBean.class).intArray.length; }
    @Benchmark public long t9_3_4_smallMapSerialize() throws Exception { return mapper.writeValueAsBytes(collSmallMap).length; }
    @Benchmark public long t9_3_5_largeMapSerialize() throws Exception { return mapper.writeValueAsBytes(collLargeMap).length; }
    @Benchmark public long t9_3_6_largeMapDeserialize() throws Exception { return mapper.readValue(collLargeMapBytes, CollectionBean.class).intMap.size(); }
    @Benchmark public long t9_3_7_nestedCollectionSerialize() throws Exception { return mapper.writeValueAsBytes(nestedColl).length; }
    @Benchmark public long t9_3_8_nestedCollectionDeserialize() throws Exception { return mapper.readValue(nestedCollBytes, NestedCollBean.class).data.size(); }
    @Benchmark public long t9_3_9_largeFloat64ArraySerialize() throws Exception { return mapper.writeValueAsBytes(collLargeFloatArr).length; }

    @Benchmark public long t9_4_1_deepNestedSerialize() throws Exception { return mapper.writeValueAsBytes(deep).length; }
    @Benchmark public long t9_4_2_deepNestedDeserialize() throws Exception { return mapper.readValue(deepBytes, DeepNested.class).level1.level2.level3.count; }
    @Benchmark public long t9_4_3_wideSerialize() throws Exception { return mapper.writeValueAsBytes(wide).length; }
    @Benchmark public long t9_4_4_wideDeserialize() throws Exception { return mapper.readValue(wideBytes, WideNested.class).f1; }
    @Benchmark public long t9_4_5_ultraWideSerialize() throws Exception { return mapper.writeValueAsBytes(ultra).length; }
    @Benchmark public long t9_4_6_ultraWideDeserialize() throws Exception { return mapper.readValue(ultraBytes, UltraWide.class).f49; }

    // ---- T9.5 coverage (8) ----

    @Benchmark public long t9_5_1_optionSerialize() throws Exception { return mapper.writeValueAsBytes(optionMixed).length; }
    @Benchmark public long t9_5_2_optionDeserialize() throws Exception { OptionBean o = mapper.readValue(optionBytes, OptionBean.class); return (o.count == null) ? 0 : o.count; }
    @Benchmark public long t9_5_3_optionRoundTrip() throws Exception { OptionBean o = mapper.readValue(mapper.writeValueAsBytes(optionFull), OptionBean.class); return (o.count == null) ? 0 : o.count; }
    @Benchmark public long t9_5_4_emptyContainersSerialize() throws Exception { return mapper.writeValueAsBytes(emptyBean).length; }
    @Benchmark public long t9_5_5_emptyContainersDeserialize() throws Exception { return mapper.readValue(emptyBytes, EmptyBean.class).arr.length; }
    @Benchmark public long t9_5_6_int64ExtremesSerialize() throws Exception { return mapper.writeValueAsBytes(extBean).length; }
    @Benchmark public long t9_5_7_int64ExtremesDeserialize() throws Exception { return mapper.readValue(extBytes, ExtremeBean.class).a; }
    @Benchmark public long t9_5_8_unknownFieldDeserialize() throws Exception { return mapper.readValue(unknownBytes, CollectionBean.class).intArray.length; }

    // ---- bytes/stream track (3) ----

    @Benchmark public long t9_b_1_bytesParsePrimitive() throws Exception { return mapper.readValue(primBytes, PrimitiveBean.class).i64; }
    @Benchmark public long t9_b_2_bytesParseLargeDoc() throws Exception { return mapper.readValue(largeDocBytes, LargeDoc.class).items.size(); }
    @Benchmark public long t9_b_3_streamLargeDoc() throws Exception { return mapper.readValue(new ByteArrayInputStream(largeDocBytes), LargeDoc.class).items.size(); }
}
