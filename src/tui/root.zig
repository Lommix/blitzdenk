const rect = @import("rect.zig");
const cell = @import("cell.zig");
const buf = @import("buffer.zig");
const term = @import("terminal.zig");
pub const widgets = @import("widgets.zig");
pub const text_utils = @import("text_utils.zig");
pub const icon = @import("icon.zig");
pub const markdown = @import("markdown.zig");
pub const MarkdownStreamingHighlighter = markdown.MarkdownStreamingHighlighter;
pub const HighlightTheme = markdown.HighlightTheme;
pub const wrapLine = widgets.wrapLine;

// Geometry + Layout
pub const Rect = rect.Rect;
pub const Constr = rect.Constraint;
pub const Row = rect.Row;
pub const Col = rect.Col;
pub const Pad = rect.Pad;
pub const Centered = rect.Centered;
pub const splitRow = rect.splitRow;
pub const splitCol = rect.splitCol;

// Cells + Styling
pub const Cell = cell.Cell;
pub const Style = cell.Style;
pub const Color = cell.Color;
pub const Modifier = cell.Modifier;

// Buffer
pub const Buffer = buf.Buffer;

// Terminal
pub const Terminal = term.Terminal;
pub const Event = term.Terminal.Event;
pub const Key = term.Terminal.Key;
pub const KeyCode = term.Terminal.KeyCode;
pub const Modifiers = term.Terminal.Modifiers;
pub const Mouse = term.Terminal.Mouse;
pub const MouseButton = term.Terminal.MouseButton;
pub const MouseAction = term.Terminal.MouseAction;

// Widgets
pub const Widget = widgets.Widget;
pub const Block = widgets.Block;
pub const Borders = widgets.Borders;
pub const BorderSet = widgets.BorderSet;
pub const Text = widgets.Text;
pub const Paragraph = widgets.Paragraph;
pub const Span = widgets.Span;
pub const Line = widgets.Line;
pub const List = widgets.List;
pub const ListItem = widgets.ListItem;
pub const Diff = widgets.Diff;
pub const DiffLine = widgets.DiffLine;
pub const DiffLineKind = widgets.DiffLineKind;
pub const Input = widgets.Input;

test {
    @import("std").testing.refAllDecls(@This());
}
