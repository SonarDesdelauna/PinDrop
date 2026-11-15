import Foundation
import Supabase

/// Supabase project configuration. The key is the public (publishable / anon) client key:
/// every table and bucket is protected by Row Level Security on the server.
enum SupabaseConfig {
    static let url = URL(string: "https://PROJECT_REF.supabase.co")!
    static let publishableKey = "PUBLISHABLE_KEY"

    /// Deep link used by confirmation and password-reset emails.
    static let authRedirectURL = URL(string: "pindrop://auth-callback")!

    static let avatarsBucket = "avatars"
    static let pinsBucket = "pins"

    /// Public URL of an avatar stored in the `avatars` bucket.
    static func publicAvatarURL(path: String) -> URL? {
        URL(string: "\(url.absoluteString)/storage/v1/object/public/\(avatarsBucket)/\(path)")
    }
}

/// Shared Supabase client.
enum Backend {
    static let client = SupabaseClient(
        supabaseURL: SupabaseConfig.url,
        supabaseKey: SupabaseConfig.publishableKey,
        options: SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(
                redirectToURL: SupabaseConfig.authRedirectURL,
                emitLocalSessionAsInitialSession: true
            )
        )
    )
}
