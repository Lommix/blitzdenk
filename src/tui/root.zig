const rect = @import("rect.zig");
const cell = @import("cell.zig");
const buf = @import("buffer.zig");
const term = @import("terminal.zig");
const markdown = @import("markdown.zig");
pub const widgets = @import("widgets.zig");
pub const text_utils = @import("text_utils.zig");
pub const icon = @import("icon.zig");
pub const AnsiWriter = @import("ansi.zig").AnsiWriter;
pub const MarkdownStreamRenderer = markdown.MarkdownStreamRenderer;
pub const HighlightTheme = markdown.HighlightTheme;
pub const wrapLine = widgets.wrapLine;

// Geometry + Layout
pub const Rect = rect.Rect;
pub const Constr = rect.Constraint;
pub const Col = rect.Col;

// Cells + Styling
pub const Cell = cell.Cell;
pub const Style = cell.Style;
pub const Color = cell.Color;

// Buffer
pub const Buffer = buf.Buffer;

// Terminal
pub const Terminal = term.Terminal;
pub const Key = term.Terminal.Key;

// Widgets
pub const Block = widgets.Block;
pub const Text = widgets.Text;
pub const Paragraph = widgets.Paragraph;
pub const Span = widgets.Span;
pub const Line = widgets.Line;
pub const DiffLine = widgets.DiffLine;
pub const DiffLineKind = widgets.DiffLineKind;
pub const Input = widgets.Input;

test {
    @import("std").testing.refAllDecls(@This());
}
