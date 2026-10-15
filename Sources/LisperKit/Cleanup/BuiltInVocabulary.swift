import Foundation

/// Tech, AI and startup/business terms Whisper routinely mangles ("clawed" for Claude,
/// "ChatGBT", "get hub") — known out of the box so a new user's dictionary isn't the only
/// line of defence. Sent to the cleanup LLM only (never as a Whisper prompt: prompt terms are
/// what Whisper regurgitates on low-confidence audio — see DictationPipeline). The user's own
/// dictionary always takes precedence and is listed separately.
public enum BuiltInVocabulary {
    public static let terms: [String] = [
        // AI
        "Claude", "Claude Code", "Anthropic", "ChatGPT", "OpenAI", "GPT", "Gemini", "Copilot",
        "Cursor", "Perplexity", "Midjourney", "Hugging Face", "LangChain", "Llama", "Groq",
        "Whisper", "Wispr Flow", "LLM", "AI agent", "MCP",
        // Dev
        "GitHub", "GitLab", "Vercel", "Supabase", "Firebase", "Netlify", "Cloudflare", "AWS",
        "Docker", "Kubernetes", "PostgreSQL", "SQLite", "Redis", "Next.js", "React",
        "TypeScript", "JavaScript", "Node.js", "Python", "Swift", "SwiftUI", "Xcode", "macOS",
        "iOS", "npm", "API", "SDK", "CLI", "JSON", "YAML", "OAuth", "README", "localhost",
        "repo", "PR", "CI/CD", "DevOps",
        // Business & growth
        "SaaS", "B2B", "B2C", "MRR", "ARR", "CAC", "LTV", "ROAS", "ROI", "CTR", "CPM", "CPC",
        "KPI", "OKR", "P&L", "EBITDA", "GTM", "PMF", "MVP", "Y Combinator", "YC", "VC",
        "Series A", "cap table", "Stripe", "Shopify", "HubSpot", "Salesforce", "Notion",
        "Slack", "Figma", "Linear", "Jira", "Zapier", "TikTok", "YouTube", "Instagram",
        "LinkedIn", "Meta Ads Manager", "Reddit",
    ]

    /// The built-ins minus anything already in the user's dictionary (case-insensitive), so
    /// a term is listed once, under the user's stronger instruction.
    public static func terms(excluding userTerms: [String]) -> [String] {
        let taken = Set(userTerms.map { $0.lowercased() })
        return terms.filter { !taken.contains($0.lowercased()) }
    }
}
