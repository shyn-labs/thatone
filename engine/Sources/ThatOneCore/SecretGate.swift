import Foundation

public enum SecretGate {
    /// Copied verbatim from shyn's `containsSecret` (CaptureCore/Gate.swift). Case-sensitive and prefix-anchored so
    /// they fire on real credentials and not on prose that merely talks about tokens. A match makes thatone skip the
    /// whole file: an image embedding cannot be redacted, so text-only scrubbing would not be enough.
    static let patterns: [String] = [
        "-----BEGIN [A-Z ]*PRIVATE KEY-----",
        "cfat_[A-Za-z0-9_-]{20,}",                 // Cloudflare API token
        "ghp_[A-Za-z0-9]{36}",                     // GitHub PAT (classic)
        "github_pat_[A-Za-z0-9_]{22,}",            // GitHub PAT (fine-grained)
        "gh[osru]_[A-Za-z0-9]{36}",                // GitHub oauth/server/refresh/user
        "sk-(ant-)?[A-Za-z0-9-]{20,}",             // OpenAI / Anthropic
        "AKIA[0-9A-Z]{16}",                        // AWS access key id
        "AIza[0-9A-Za-z_-]{35}",                   // Google API key
        "xox[baprs]-[A-Za-z0-9-]{10,}",            // Slack
        "(sk|rk|pk)_live_[0-9A-Za-z]{20,}",        // Stripe live
    ]

    public static func containsSecret(_ text: String) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
