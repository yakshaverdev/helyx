//! The window of the app on macOS (`docs/features/client-kit.md`, slice 4):
//! the live sessions of the server on the left, the transcript of the
//! followed one on the right. The rows come from `transcript::rows`; the
//! list draws only the rows in view. A UI block draws by its model of
//! `vocabulary` (`docs/features/ui-blocks.md`, "Rendering in the client
//! kit"): under its tool result, under the oldest open call of its call id,
//! or at the end of the turn.

use gpui::{
    AnyElement, App, Application, Bounds, Context, FontWeight, ListAlignment, ListState,
    SharedString, Window, WindowBounds, WindowOptions, div, list, prelude::*, px, rgb, size,
};
use helyx_client_core::fold::State;
use helyx_client_core::message::{Block, Message, Role};
use helyx_client_core::transcript::{Row, open_calls, rows};
use helyx_client_core::ui_block::MAX_BYTES;
use helyx_client_core::vocabulary::{
    Approval, Form, MAX_ARGUMENTS_BYTES, MAX_NAME_BYTES, MAX_TITLE_BYTES, UiBlock, View, head,
};
use helyx_desktop::net::{self, Command, Shared};
use helyx_desktop::settings::Server;
use std::collections::HashMap;
use std::sync::mpsc::{Sender, channel, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How often the window takes the changes of the network thread.
const REDRAW: Duration = Duration::from_millis(50);
const DIM: u32 = 0x9a9a9a;

/// One item of the transcript list.
#[derive(Clone)]
enum Item {
    Text(SharedString, u32),
    /// A UI block; `ask` when it is the request of an open ask, which this
    /// app does not answer.
    Block {
        block: UiBlock,
        ask: bool,
    },
}

struct Desktop {
    shared: Arc<Mutex<Shared>>,
    commands: Sender<Command>,
    transcript: ListState,
}

/// Opens the window and runs the network thread for `server`.
pub fn run(server: Server) {
    let shared = Arc::new(Mutex::new(Shared::new(server.token.clone())));
    let (commands, receive) = channel();
    // One slot: a change that finds it full is in the next redraw anyway.
    let (changed, changes) = sync_channel::<()>(1);
    let thread_shared = shared.clone();
    std::thread::spawn(move || {
        net::run(&server, &thread_shared, &receive, &|| {
            let _ = changed.try_send(());
        })
    });
    Application::new().run(move |cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(1000.), px(700.)), cx);
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            ..Default::default()
        };
        cx.open_window(options, |_, cx| {
            cx.new(|cx| {
                cx.spawn(async move |this, cx| {
                    loop {
                        cx.background_executor().timer(REDRAW).await;
                        if changes.try_iter().count() > 0
                            && this
                                .update(cx, |view: &mut Desktop, cx| view.changed(cx))
                                .is_err()
                        {
                            break;
                        }
                    }
                })
                .detach();
                Desktop {
                    shared,
                    commands,
                    transcript: ListState::new(0, ListAlignment::Bottom, px(500.)),
                }
            })
        })
        .expect("a window");
        cx.activate(true);
    });
}

impl Desktop {
    /// The network thread changed the state.
    fn changed(&mut self, cx: &mut Context<Self>) {
        cx.notify();
    }

    /// The state of the network thread. A panic of the thread while it held
    /// the lock leaves its last state, which the window shows on.
    fn shared(&self) -> std::sync::MutexGuard<'_, Shared> {
        self.shared
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The items of the followed session.
    fn rows(&self) -> Vec<Item> {
        let shared = self.shared();
        shared
            .followed
            .as_deref()
            .and_then(|s| shared.client.state(s))
            .map_or_else(Vec::new, items)
    }
}

/// The items of `state`: each row, each tool result with its UI blocks, and
/// the shown blocks and the asks of a call under the oldest open call of its
/// id; the partial, the blocks and asks with no open call, and the notices
/// at the end.
fn items(state: &State) -> Vec<Item> {
    let rows = rows(&state.messages);
    let open = open_calls(&rows);
    let mut under: HashMap<usize, Vec<Item>> = HashMap::new();
    let mut end = vec![];
    let mut place = |call_id: Option<&str>, item| match call_id.and_then(|id| open.get(id)) {
        Some(at) => under.entry(*at).or_default().push(item),
        None => end.push(item),
    };
    for shown in &state.ui_blocks {
        let block = UiBlock::read(&shown.block).expect("the core checked the block");
        place(shown.call_id.as_deref(), Item::Block { block, ask: false });
    }
    for ask in &state.asks {
        if let Some(block) = ask.block() {
            place(Some(&ask.call_id), Item::Block { block, ask: true });
        }
    }
    let mut items = Vec::with_capacity(rows.len() + end.len());
    for (at, shown) in rows.iter().enumerate() {
        items.push(row(shown));
        if let Row::Call {
            result: Some(result),
            ..
        } = shown
        {
            items.extend(result.ui_blocks.iter().map(|value| Item::Block {
                block: UiBlock::read(value).expect("the core checked the block"),
                ask: false,
            }));
        }
        items.extend(under.remove(&at).unwrap_or_default());
    }
    if let Some(partial) = &state.partial {
        items.push(Item::Text(text(partial).into(), DIM));
    }
    items.extend(end);
    items.extend(
        (state.notices.iter()).map(|n| Item::Text(SharedString::from(format!("✕ {n}")), 0xd06060)),
    );
    items
}

fn row(row: &Row<'_>) -> Item {
    match row {
        Row::Message(m) if m.role == Role::User => {
            Item::Text(format!("› {}", text(m)).into(), 0xffffff)
        }
        Row::Message(m) => Item::Text(text(m).into(), 0xdddddd),
        Row::Call {
            call: Block::ToolCall { name, .. },
            result,
        } => {
            let shown = result.map_or("awaiting result".to_owned(), text);
            Item::Text(format!("⏺ {name}\n{shown}").into(), 0x8fb8de)
        }
        Row::Call { .. } => unreachable!("a call row holds a tool call"),
        Row::Orphan(result) => Item::Text(
            format!("a tool result with no call\n{}", text(result)).into(),
            0xc0a060,
        ),
    }
}

/// The text of a message, with a placeholder for each block that is not
/// text: a block kind that the app does not know shows its kind.
fn text(message: &Message) -> String {
    message
        .content
        .iter()
        .filter_map(|block| match block {
            Block::Text(text) => Some(text.clone()),
            Block::Thinking(text) => Some(format!("({text})")),
            Block::ToolCall { .. } => None,
            Block::Unknown(kind) => Some(format!("[{kind}]")),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

impl Render for Desktop {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let (live, followed, line, running) = {
            let shared = self.shared();
            let state = shared
                .followed
                .as_deref()
                .and_then(|s| shared.client.state(s));
            // A follow that waits or is held says why, derived on read.
            let line = shared
                .followed
                .as_deref()
                .and_then(|s| net::follow_line(s, &shared.client.follow(s)?))
                .unwrap_or_else(|| shared.line.clone());
            (
                shared.live.clone(),
                shared.followed.clone(),
                line,
                state.is_some_and(|s| s.running),
            )
        };
        // The count of the list and the rows that it draws are one snapshot.
        let shown = self.rows();
        if shown.len() != self.transcript.item_count() {
            self.transcript.reset(shown.len());
        }
        let sessions = live.into_iter().map(|session| {
            let id = session.id.clone();
            let chosen = followed.as_deref() == Some(id.as_str());
            div()
                .id(SharedString::from(id.clone()))
                .p_2()
                .when(chosen, |d| d.bg(rgb(0x3a3a4a)))
                .child(format!("{} · {}", session.cwd, session.model))
                .on_click(cx.listener(move |this, _, _, cx| {
                    let _ = this.commands.send(Command::Follow(id.clone()));
                    cx.notify();
                }))
        });
        div()
            .flex()
            .size_full()
            .bg(rgb(0x1e1e24))
            .text_color(rgb(0xdddddd))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .w(px(280.))
                    .border_r_1()
                    .border_color(rgb(0x3a3a3a))
                    .children(sessions),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .child(
                        div()
                            .p_2()
                            .child(format!("{line}{}", if running { " · running" } else { "" })),
                    )
                    .child(
                        list(self.transcript.clone(), move |ix, _, _| match &shown[ix] {
                            Item::Text(text, color) => div()
                                .p_2()
                                .text_color(rgb(*color))
                                .child(text.clone())
                                .into_any_element(),
                            Item::Block { block, ask } => ui_block(block, *ask),
                        })
                        .flex_1(),
                    ),
            )
    }
}

/// A UI block: a `form` and an `approval` natively, any other kind, and a
/// known kind whose fields the app cannot read, as its fallback text; a mark
/// when it was cut. An ask gets no answer from this app: it stays open for
/// another client (ADR 0011 §4).
fn ui_block(block: &UiBlock, ask: bool) -> AnyElement {
    // The text of an ask has no size check in the client: the bound of a
    // block holds when it is drawn.
    let (text, more) = head(&block.text, MAX_BYTES);
    let body = match &block.view {
        View::Form(form) => form_body(form),
        View::Approval(approval) => approval_body(&block.text, approval),
        View::Text => div().child(format!("▪ {text}")),
    };
    let cut = block.cut || (block.view == View::Text && more);
    div()
        .p_2()
        .child(
            div()
                .ml_4()
                .p_2()
                .flex()
                .flex_col()
                .gap_1()
                .border_1()
                .border_color(rgb(0x3a3a4a))
                .rounded_md()
                .text_color(rgb(0xcccccc))
                .child(body)
                .when(cut, |d| d.child(dim("[cut]")))
                .when(ask, |d| d.child(dim("answer it in another client"))),
        )
        .into_any_element()
}

fn form_body(form: &Form) -> gpui::Div {
    div()
        .flex()
        .flex_col()
        .gap_2()
        .children(form.questions.iter().map(|q| {
            let mark = if q.multi_select { "☐" } else { "○" };
            div()
                .flex()
                .flex_col()
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .child(
                            div()
                                .px_1()
                                .bg(rgb(0x3a3a4a))
                                .font_weight(FontWeight::BOLD)
                                .child(q.header.clone()),
                        )
                        .child(q.question.clone()),
                )
                .children(q.options.iter().map(move |option| {
                    div()
                        .flex()
                        .gap_2()
                        .child(format!("{mark} {}", option.label))
                        .child(dim(&option.description))
                }))
        }))
}

/// An approval within the bounds of the TUI picker: the title on one line
/// of at most 1,024 bytes, the tool and the provider at most 256 bytes
/// each, the arguments at most 16,384 bytes.
fn approval_body(title: &str, approval: &Approval) -> gpui::Div {
    let title = head(title, MAX_TITLE_BYTES).0.replace(['\n', '\r'], " ");
    let (arguments, more) = head(&approval.arguments, MAX_ARGUMENTS_BYTES);
    let of = approval
        .provider
        .as_ref()
        .map_or(String::new(), |provider| {
            format!(" of {}", head(provider, MAX_NAME_BYTES).0)
        });
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(div().font_weight(FontWeight::BOLD).child(title))
        .child(dim(&format!(
            "{}{of}",
            head(&approval.tool, MAX_NAME_BYTES).0
        )))
        .child(
            div()
                .p_1()
                .bg(rgb(0x26262e))
                .font_family("Menlo")
                .child(arguments.to_owned()),
        )
        .when(more, |d| d.child(dim("… more arguments")))
        .child(dim("Allow · Deny"))
}

fn dim(text: &str) -> gpui::Div {
    div().text_color(rgb(DIM)).child(text.to_owned())
}
