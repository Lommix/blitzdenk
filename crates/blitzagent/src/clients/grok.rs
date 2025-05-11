#![allow(unused)]

use crate::{
    chat::{ChatClient, FunctionCall, Message, Role},
    tool::AiTool,
    BResult,
};
use crossbeam::channel::Sender;
use serde::*;
use std::collections::HashMap;

pub struct GrokClient {
    url: String,
    // chat: OChat,
}
