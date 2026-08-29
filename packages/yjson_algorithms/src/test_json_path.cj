package yjson_algorithms

import yjson.*

import std.unittest.*
import std.unittest.testmacro.*

@Test
class YJsonPathTest {
    private let store = YJson.parse("""
    {"store":{"book":[{"title":"A","price":8},{"title":"B","price":12}],"bicycle":{"price":19}},"odd key":1}
    """)

    @TestCase
    func nameIndexWildcardAndNormalizedPaths(): Unit {
        let title = JsonPath.parse("$.store.book[0].title").first(store).getOrThrow()
        @Expect(title.value.string, "A")
        @Expect(title.normalizedPath, "$['store']['book'][0]['title']")
        @Expect(JsonPath.parse("$['odd key']").first(store).getOrThrow().value.int64, 1)
        @Expect(JsonPath.parse("$.store.*").query(store).size, 2)
    }

    @TestCase
    func unionSliceNegativeIndexAndDescendant(): Unit {
        let books = JsonPath.parse("$.store.book[0,1]").values(store)
        @Expect(books.size, 2)
        @Expect(JsonPath.parse("$.store.book[-1].title").first(store).getOrThrow().value.string, "B")
        @Expect(JsonPath.parse("$.store.book[::-1].title").values(store)[0].string, "B")
        @Expect(JsonPath.parse("$..price").values(store).size, 3)
    }

    @TestCase
    func invalidSyntaxIsRejectedAndZeroStepSelectsNothing(): Unit {
        @AssertThrows[JsonPathException](JsonPath.parse("store.book"))
        @Expect(JsonPath.parse("$[::0]").values(store).size, 0)
        @AssertThrows[JsonPathException](JsonPath.parse("$[]"))
        @AssertThrows[JsonPathException](JsonPath.parse("$[0,]"))
        @AssertThrows[JsonPathException](JsonPath.parse("$.1"))
        @AssertThrows[JsonPathException](JsonPath.parse("$.&"))
    }

    @TestCase
    func filtersSupportExistenceComparisonLogicAndFunctions(): Unit {
        @Expect(JsonPath.parse("$.store.book[?@.price < 10].title").first(store).getOrThrow().value.string, "A")
        @Expect(JsonPath.parse("$.store.book[?(@.price >= 10 && @.title == 'B')]").values(store).size, 1)
        @Expect(JsonPath.parse("$.store.book[?length(@.title) == 1]").values(store).size, 2)
        @Expect(JsonPath.parse("$.store.book[?match(@.title, '^[AB]$')]").values(store).size, 2)
        @Expect(JsonPath.parse("$.store.book[?match(@.title, '^Z$')]").values(store).size, 0)
        @Expect(JsonPath.parse("$.store.book[?!@.missing]").values(store).size, 2)
    }

    @TestCase
    func singularQueriesUseParsedSelectorsInsteadOfQuotedPunctuation(): Unit {
        let punctuation = YJson.parse("""
        {"items":[{"a,b":"x","a:b":"y","*":1,"?..":2}]}
        """)
        @Expect(JsonPath.parse("$.items[?length(@['a,b']) == 1]").values(punctuation).size, 1)
        @Expect(JsonPath.parse("$.items[?length(@['a:b']) == 1]").values(punctuation).size, 1)
        @Expect(JsonPath.parse("$.items[?@['*'] == 1]").values(punctuation).size, 1)
        @Expect(JsonPath.parse("$.items[?@['?..'] == 2]").values(punctuation).size, 1)
        @AssertThrows[JsonPathException](JsonPath.parse("$.items[?length(@[*]) == 1]"))
        @AssertThrows[JsonPathException](JsonPath.parse("$.items[?length(@[0,1]) == 1]"))
        @AssertThrows[JsonPathException](JsonPath.parse("$.items[?length(@[0:1]) == 1]"))
    }
}
