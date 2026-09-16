import Foundation

enum SupabaseConfig {
    private static func infoDictionaryValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static let projectURL: URL = {
        guard let ref = infoDictionaryValue(for: "SupabaseProjectRef") else {
            fatalError("SupabaseProjectRef missing from build settings")
        }
        guard let url = URL(string: "https://\(ref).supabase.co") else {
            fatalError("SupabaseProjectRef produced an invalid URL: \(ref)")
        }
        return url
    }()

    static let anonKey: String = {
        guard let value = infoDictionaryValue(for: "SupabaseAnonKey") else {
            fatalError("SupabaseAnonKey missing from build settings")
        }
        return value
    }()
}
