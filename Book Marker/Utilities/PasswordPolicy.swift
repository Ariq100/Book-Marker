import Foundation

/// Password rules for new accounts. These mirror the server-side settings in
/// supabase/config.toml (`minimum_password_length`, `password_requirements`) — the client check
/// exists for instant feedback, but Supabase Auth is what actually enforces them.
enum PasswordPolicy {
    static let minimumLength = 10
    static let maximumLength = 72 // bcrypt, which Supabase Auth uses, ignores anything longer

    /// The exact symbol set Supabase Auth accepts for `lower_upper_letters_digits_symbols`.
    /// Checking against the same set means a password the app accepts is never rejected by the
    /// server for a "missing symbol" the user thought they had typed.
    static let symbols = Set("!@#$%^&*()_+-=[]{};'\\:\"|<>?,./`~")

    struct Requirement: Identifiable {
        let id: String
        let label: String
        let isMet: Bool
    }

    static func requirements(for password: String, email: String) -> [Requirement] {
        let emailName = email.split(separator: "@").first.map { $0.lowercased() } ?? ""
        return [
            Requirement(id: "length", label: "At least \(minimumLength) characters",
                        isMet: password.count >= minimumLength && password.count <= maximumLength),
            Requirement(id: "upper", label: "An uppercase letter",
                        isMet: password.contains { $0.isASCII && $0.isUppercase }),
            Requirement(id: "lower", label: "A lowercase letter",
                        isMet: password.contains { $0.isASCII && $0.isLowercase }),
            Requirement(id: "digit", label: "A number",
                        isMet: password.contains { $0.isASCII && $0.isNumber }),
            Requirement(id: "symbol", label: "A symbol, e.g. ! ? # $ %",
                        isMet: password.contains { symbols.contains($0) }),
            Requirement(id: "email", label: "Doesn't contain your email name",
                        isMet: emailName.count < 3 || !password.lowercased().contains(emailName)),
        ]
    }

    static func isValid(_ password: String, email: String) -> Bool {
        requirements(for: password, email: email).allSatisfy(\.isMet)
    }
}
