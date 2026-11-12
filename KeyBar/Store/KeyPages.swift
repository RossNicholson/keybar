import Foundation

/// Where to make a new key for the services people rotate most. Only opened
/// when the user clicks.
enum KeyPages {
    private static let pages: [String: String] = [
        "Anthropic": "https://console.anthropic.com/settings/keys",
        "OpenAI": "https://platform.openai.com/api-keys",
        "GitHub": "https://github.com/settings/personal-access-tokens",
        "Cloudflare": "https://dash.cloudflare.com/profile/api-tokens",
        "Stripe": "https://dashboard.stripe.com/apikeys",
        "Groq": "https://console.groq.com/keys",
        "Mistral": "https://console.mistral.ai/api-keys",
        "OpenRouter": "https://openrouter.ai/settings/keys",
        "Hugging Face": "https://huggingface.co/settings/tokens",
        "Resend": "https://resend.com/api-keys",
        "Vercel": "https://vercel.com/account/tokens",
        "Netlify": "https://app.netlify.com/user/applications",
        "Sentry": "https://sentry.io/settings/account/api/auth-tokens/",
        "Google": "https://console.cloud.google.com/apis/credentials",
        "Google Gemini": "https://aistudio.google.com/apikey",
        "Google Cloud": "https://console.cloud.google.com/apis/credentials",
        "Google Search Console": "https://console.cloud.google.com/iam-admin/serviceaccounts",
        "Replicate": "https://replicate.com/account/api-tokens",
        "ElevenLabs": "https://elevenlabs.io/app/settings/api-keys",
        "Supabase": "https://supabase.com/dashboard/project/_/settings/api-keys",
        "Slack": "https://api.slack.com/apps",
        "npm": "https://www.npmjs.com/settings/~/tokens",
    ]

    static func url(for record: SecretRecord) -> URL? {
        record.service.flatMap { pages[$0.name] }.flatMap(URL.init(string:))
    }
}
