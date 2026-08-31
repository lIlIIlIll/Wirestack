package yjson_algorithms

import yjson.*

import std.unittest.*
import std.unittest.testmacro.*

@Test
class LinearRegexTest {
    @TestCase
    func literalsChoicesClassesAndBoundsUseFullUnicodeInput(): Unit {
        @Expect(matches("^(?:cat|dog)s?$", "cats"))
        @Expect(matches("^[A-Z]{2}\\d{2}$", "CJ01"))
        @Expect(!matches("^[A-Z]{2}\\d{2}$", "Cj01"))
        @Expect(matches("^\\p{Letter}+\\p{digit}*$", "仓颉１２"))
        @Expect(matches("^🐲*$", "🐲🐲"))
        @Expect(matches("^\\uD83D\\uDC32$", "🐲"))
    }

    @TestCase
    func searchFullAnchorsDotsEscapesAndEmptyClassesHaveDeterministicSemantics(): Unit {
        @Expect(matches("a.b", "xxa中byy"))
        @Expect(!matches("a.b", "a\nb"))
        @Expect(matches("a\\[.c", "a[xc"))
        @Expect(matches("\\bjson\\b", "safe json value"))
        @Expect(!matches("[]", "x"))
        @Expect(matches("[^]", "\n"))

        let fullBudget = LinearRegexBudget(10000, "regex test steps")
        let full = LinearRegex.compile("a.b", fullBudget)
        @Expect(full.find("a中b", fullBudget, full: true))
        @Expect(!full.find("xa中b", fullBudget, full: true))
    }

    @TestCase
    func iRegexpDotIncludesUnicodeLineSeparatorsButNotCrOrLf(): Unit {
        @Expect(!matches(".", "\u{2028}"))
        @Expect(!matches(".", "\u{2029}"))

        let budget = LinearRegexBudget(10000, "regex test steps")
        let regex = LinearRegex.compile(".", budget, iRegexp: true)
        @Expect(regex.find("\u{2028}", budget, full: true))
        @Expect(regex.find("\u{2029}", budget, full: true))
        @Expect(!regex.find("\r", budget, full: true))
        @Expect(!regex.find("\n", budget, full: true))
    }

    @TestCase
    func nonRegularFeaturesFailClosedAtCompilation(): Unit {
        @Expect(@AssertThrows[JsonException](compile("(a)\\1")).code, "invalid_regex")
        @Expect(@AssertThrows[JsonException](compile("(?=a)")).code, "invalid_regex")
        @Expect(@AssertThrows[JsonException](compile("(?<=a)")).code, "invalid_regex")
    }

    @TestCase
    func nestedQuantifiersConsumeLinearStateBudgetInsteadOfBacktracking(): Unit {
        let budget = LinearRegexBudget(200, "regex test steps")
        let regex = LinearRegex.compile("^(a+)+$", budget)
        budget.reset()
        let value = StringBuilder()
        for (_ in 0..1000) { value.append("a") }
        value.append("X")
        @Expect(@AssertThrows[JsonException](regex.find(value.toString(), budget)).code,
            "work_limit_exceeded")
    }

    private func matches(pattern: String, value: String): Bool {
        let budget = LinearRegexBudget(10000, "regex test steps")
        LinearRegex.compile(pattern, budget).find(value, budget)
    }

    private func compile(pattern: String): LinearRegex {
        LinearRegex.compile(pattern, LinearRegexBudget(10000, "regex test steps"))
    }
}
