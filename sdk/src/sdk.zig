const std = @import("std");

pub const types = @import("types.zig");
pub const model = @import("model.zig");
pub const options = @import("options.zig");
pub const errors = @import("errors.zig");
pub const auth = @import("auth.zig");
pub const schema = @import("schema.zig");
pub const provider = @import("provider/root.zig");

pub const Role = types.Role;
pub const Part = types.Part;
pub const PartType = types.PartType;
pub const Message = types.Message;
pub const ToolCall = types.ToolCall;
pub const ToolResult = types.ToolResult;
pub const ToolOutput = types.ToolOutput;
pub const ToolImage = types.ToolImage;
pub const Usage = types.Usage;
pub const FinishReason = types.FinishReason;
pub const StreamChunk = types.StreamChunk;
pub const StreamChunkType = types.StreamChunkType;
pub const ResponseMetadata = types.ResponseMetadata;
pub const TextResult = types.TextResult;
pub const StepResult = types.StepResult;
pub const ObjectResult = types.ObjectResult;
pub const EmbedResult = types.EmbedResult;
pub const ImageResult = types.ImageResult;
pub const ImageData = types.ImageData;
pub const Tool = types.Tool;
pub const ResponseFormat = types.ResponseFormat;

pub const SystemMessage = types.SystemMessage;
pub const UserMessage = types.UserMessage;
pub const AssistantMessage = types.AssistantMessage;
pub const ToolMessage = types.ToolMessage;
pub const DeveloperMessage = types.DeveloperMessage;

pub const LanguageModel = model.LanguageModel;
pub const EmbeddingModel = model.EmbeddingModel;
pub const ImageModel = model.ImageModel;

pub const GenerateOptions = options.GenerateOptions;
pub const EmbedOptions = options.EmbedOptions;
pub const ImageOptions = options.ImageOptions;
pub const StreamCallbacks = options.StreamCallbacks;
pub const Hooks = options.Hooks;
pub const ToolChoice = options.ToolChoice;
pub const CancellationToken = options.CancellationToken;

pub const APIError = errors.APIError;
pub const ContextOverflowError = errors.ContextOverflowError;
pub const SdkError = errors.SdkError;
pub const isOverflow = errors.isOverflow;

pub const Env = auth.Env;

pub const openai = provider.openai;
pub const anthropic = provider.anthropic;
pub const responses = provider.responses;
pub const compat = provider.compat;

pub const generate = @import("generate.zig");
pub const complete = generate.complete;
pub const streamText = generate.streamText;
pub const generateObject = generate.generateObject;
pub const streamObject = generate.streamObject;
pub const embed = @import("embed.zig").embed;
pub const embedMany = @import("embed.zig").embedMany;
pub const generateImage = @import("image.zig").generateImage;
pub const schemaFrom = schema.schemaFrom;

test {
    std.testing.refAllDecls(@This());
    _ = types;
    _ = model;
    _ = options;
    _ = errors;
    _ = auth;
    _ = schema;
    _ = generate;
    _ = embed;
    _ = provider;
}
