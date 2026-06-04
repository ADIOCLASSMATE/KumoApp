enum ProxyGroupOrdering {
    /// Orders live proxy groups to match the sequence in the active runtime
    /// configuration. Groups created by mihomo at runtime are appended in
    /// their existing order.
    static func matchingConfiguration(
        _ groups: [ProxyGroup],
        configuredGroupNames: [String]
    ) -> [ProxyGroup] {
        var configuredRanks: [String: Int] = [:]
        for (index, name) in configuredGroupNames.enumerated() where configuredRanks[name] == nil {
            configuredRanks[name] = index
        }

        return groups.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = configuredRanks[lhs.element.name]
                let rhsRank = configuredRanks[rhs.element.name]

                switch (lhsRank, rhsRank) {
                case let (.some(lhsRank), .some(rhsRank)):
                    return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}
