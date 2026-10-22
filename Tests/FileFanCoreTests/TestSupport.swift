import Testing

func requireValue<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, sourceLocation: sourceLocation)
}

func expectNotEqual<T: Equatable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual != expected, sourceLocation: sourceLocation)
}

func expectTrue(_ condition: Bool, _ comment: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(condition, Comment(rawValue: comment), sourceLocation: sourceLocation)
}

func expectFalse(_ condition: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!condition, sourceLocation: sourceLocation)
}

func expectGreaterThan<T: Comparable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual > expected, sourceLocation: sourceLocation)
}

func expectLessThan<T: Comparable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual < expected, sourceLocation: sourceLocation)
}

func expectThrows<T>(_ expression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation, inspect: ((Error) -> Void)? = nil) {
    do {
        _ = try expression()
        Issue.record("Expected an error", sourceLocation: sourceLocation)
    } catch {
        inspect?(error)
    }
}
