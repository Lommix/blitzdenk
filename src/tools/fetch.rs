use crate::agent::{AgentContext, AiTool, ToolArgs};
use crate::error::AFuture;
use genai::chat::*;
use scraper::Html;
use serde_json::json;

pub struct Fetch;

impl AiTool for Fetch {
    fn name(&self) -> &'static str {
        "fetch"
    }

    fn description(&self) -> Option<&'static str> {
        Some(
            r#"
- Fetches content from a specified URL
- Takes a URL as input
- Fetches the URL content, converts HTML to markdown
- Use this tool when you need to retrieve and analyze web content

Usage notes:
  - IMPORTANT: If an MCP-provided web fetch tool is available, prefer using that tool instead of this one, as it may have fewer restrictions. All MCP-provided tools start with "mcp__".
  - The URL must be a fully-formed valid URL
  - HTTP URLs will be automatically upgraded to HTTPS
  - The prompt should describe what information you want to extract from the page
  - This tool is read-only and does not modify any files
  - Results may be summarized if the content is very large
  - Includes a self-cleaning 15-minute cache for faster responses when repeatedly accessing the same URL
        "#,
        )
    }

    fn schema(&self) -> Option<serde_json::Value> {
        Some(json!({
            "type" : "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "The URL to fetch content from"
                },
            },
            "required": ["url"],
        }))
    }

    fn run(tool_id: String, args: ToolArgs, _ctx: AgentContext) -> AFuture<ChatMessage> {
        Box::pin(async move {
            let url = args.get::<String>("url")?;
            let html = reqwest::Client::new().get(url).send().await?.text().await?;
            let parsed = Html::parse_document(&html);

            let selector = scraper::Selector::parse("main").unwrap();
            let content: String = parsed
                .select(&selector)
                .map(|el| el.text().collect::<String>())
                .collect();

            Ok(ToolResponse::new(tool_id, content).into())
        })
    }
}
