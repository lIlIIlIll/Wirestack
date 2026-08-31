package yjson_algorithms

import yjson.*

import std.unittest.*
import std.unittest.testmacro.*

@Test
class YJsonPathTest {
    private let store = JsonNode.parse("""
    {"store":{"book":[{"title":"A","price":8},{"title":"B","price":12}],"bicycle":{"price":19}},"odd key":1}
    """)

    @TestCase
    func nameIndexWildcardAndNormalizedPaths(): Unit {
        let title = JsonPath.parse("$.store.book[0].title").first(store).getOrThrow()
        @Expect(title.value.asString(), "A")
        @Expect(title.normalizedPath, "$['store']['book'][0]['title']")
        @Expect(JsonPath.parse("$['odd key']").first(store).getOrThrow().value.asInt64(), 1)
        @Expect(JsonPath.parse("$.store.*").collect(store).size, 2)
    }

    @TestCase
    func unionSliceNegativeIndexAndDescendant(): Unit {
        let books = JsonPath.parse("$.store.book[0,1]").collectValues(store)
        @Expect(books.size, 2)
        @Expect(JsonPath.parse("$.store.book[-1].title").first(store).getOrThrow().value.asString(), "B")
        @Expect(JsonPath.parse("$.store.book[::-1].title").collectValues(store)[0].asString(), "B")
        @Expect(JsonPath.parse("$..price").collectValues(store).size, 3)
    }

    @TestCase
    func invalidSyntaxIsRejectedAndZeroStepSelectsNothing(): Unit {
        @Expect(@AssertThrows[JsonException](JsonPath.parse("store.book")).code, "invalid_json_path")
        @Expect(JsonPath.parse("$[::0]").collectValues(store).size, 0)
        @Expect(@AssertThrows[JsonException](JsonPath.parse("$[]")).code, "invalid_json_path")
        @Expect(@AssertThrows[JsonException](JsonPath.parse("$[0,]")).code, "invalid_json_path")
        @Expect(@AssertThrows[JsonException](JsonPath.parse("$.1")).code, "invalid_json_path")
        @Expect(@AssertThrows[JsonException](JsonPath.parse("$.&")).code, "invalid_json_path")
    }

    @TestCase
    func filtersSupportExistenceComparisonLogicAndFunctions(): Unit {
        @Expect(JsonPath.parse("$.store.book[?@.price < 10].title").first(store).getOrThrow().value.asString(), "A")
        @Expect(JsonPath.parse("$.store.book[?(@.price >= 10 && @.title == 'B')]").collectValues(store).size, 1)
        @Expect(JsonPath.parse("$.store.book[?length(@.title) == 1]").collectValues(store).size, 2)
        @Expect(JsonPath.parse("$.store.book[?match(@.title, '^[AB]$')]").collectValues(store).size, 2)
        @Expect(JsonPath.parse("$.store.book[?match(@.title, '^Z$')]").collectValues(store).size, 0)
        @Expect(JsonPath.parse("$.store.book[?!@.missing]").collectValues(store).size, 2)
    }

    @TestCase
    func regexFunctionsUseTheConfiguredLinearWorkBudget(): Unit {
        let path = JsonPath.parse("$.store.book[?match(@.title, '^[AB]$')]")
        let error = @AssertThrows[JsonException](path.collectValues(store,
            limits: JsonPathLimits(maxRegexSteps: 1)))
        @Expect(error.code, "work_limit_exceeded")
    }

    @TestCase
    func singularQueriesUseParsedSelectorsInsteadOfQuotedPunctuation(): Unit {
        let punctuation = JsonNode.parse("""
        {"items":[{"a,b":"x","a:b":"y","*":1,"?..":2}]}
        """)
        @Expect(JsonPath.parse("$.items[?length(@['a,b']) == 1]").collectValues(punctuation).size, 1)
        @Expect(JsonPath.parse("$.items[?length(@['a:b']) == 1]").collectValues(punctuation).size, 1)
        @Expect(JsonPath.parse("$.items[?@['*'] == 1]").collectValues(punctuation).size, 1)
        @Expect(JsonPath.parse("$.items[?@['?..'] == 2]").collectValues(punctuation).size, 1)
        @Expect(@AssertThrows[JsonException](JsonPath.parse("$.items[?length(@[*]) == 1]")).code,
            "invalid_json_path")
        @Expect(@AssertThrows[JsonException](JsonPath.parse("$.items[?length(@[0,1]) == 1]")).code,
            "invalid_json_path")
        @Expect(@AssertThrows[JsonException](JsonPath.parse("$.items[?length(@[0:1]) == 1]")).code,
            "invalid_json_path")
    }

    @TestCase
    func singularFunctionQueriesAllowWhitespaceBetweenSelectors(): Unit {
        let nested = JsonNode.parse("""
        [{"a":{"b":"foo"}},{}]
        """)
        @Expect(JsonPath.parse("$[?length(@ .a .b) == 3]").collectValues(nested).size, 1)
        @Expect(JsonPath.parse("$[?length(@\n.a\n.b) == 3]").collectValues(nested).size, 1)
        @Expect(JsonPath.parse("$[?length(@\t.a\t.b) == 3]").collectValues(nested).size, 1)
        @Expect(JsonPath.parse("$[?length(@\r.a\r.b) == 3]").collectValues(nested).size, 1)
    }

    @TestCase
    func cursorIsLazyAndFirstStopsAfterTheFirstMatch(): Unit {
        let values = JsonNode.parse("[1,2,3]")
        let path = JsonPath.parse("$[*]")
        let untouched = path.matches(values,
            limits: JsonPathLimits(maxVisitedNodes: 1, maxMatches: 1))
        let budgetError = @AssertThrows[JsonException](untouched.next())
        @Expect(budgetError.code, "work_limit_exceeded")

        let first = path.first(values,
            limits: JsonPathLimits(maxVisitedNodes: 2, maxMatches: 1)).getOrThrow()
        @Expect(first.value.asInt64(), 1)
        @Expect(first.normalizedPath, "$[0]")

        let cursor = path.matches(values)
        @Expect(cursor.next().getOrThrow().value.asInt64(), 1)
        @Expect(cursor.next().getOrThrow().value.asInt64(), 2)
        @Expect(cursor.next().getOrThrow().value.asInt64(), 3)
        @Expect(cursor.next().isNone())
    }
}
