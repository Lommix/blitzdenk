use crate::{
    agent::{AgentArgs, AgentContext},
    chat::{Argument, Message},
    BResult,
};

#[async_trait::async_trait]
pub trait AiTool: Send + Sync + 'static {
    fn name(&self) -> &'static str;
    fn description(&self) -> &'static str;

    fn args(&self) -> Vec<Argument> {
        vec![]
    }

    async fn run(&self, ctx: AgentContext, args: AgentArgs) -> BResult<Message>;
}
