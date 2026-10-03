import Foundation

enum Classifier {
    struct Result {
        let category: Category
        let matchedRule: String?
    }

    static let urlUnavailable = "browser-url-unavailable"

    static func classify(bundleID: String, domain: String?, isBrowser: Bool,
                         rules: [Rule]) -> Result {
        if let domain {
            for rule in rules {
                if rule.type == .default || (rule.type == .domain &&
                    (domain == rule.match || domain.hasSuffix("." + rule.match))) {
                    return result(for: rule)
                }
            }
        } else {
            if let rule = rules.first(where: { $0.type == .bundle && $0.match == bundleID }) {
                return result(for: rule)
            }
            if isBrowser {
                return Result(category: .unknown, matchedRule: urlUnavailable)
            }
            if let rule = rules.first(where: { $0.type == .default }) {
                return result(for: rule)
            }
        }
        return Result(category: .red, matchedRule: nil)
    }

    private static func result(for rule: Rule) -> Result {
        Result(category: rule.category, matchedRule: "\(rule.type.rawValue):\(rule.match)")
    }
}
