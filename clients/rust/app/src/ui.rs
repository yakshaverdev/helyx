//! The window of the app on macOS (`docs/features/client-kit.md`, slice 4):
//! the live and saved sessions on the left, the transcript of the followed
//! one on the right, and the composer, the request lines, and the ask under
//! it. The rows come from `transcript::rows`; the list draws only the rows in
//! view. A UI block draws by its model of `vocabulary`
//! (`docs/features/ui-blocks.md`, "Rendering in the client kit"): under its
//! tool result, under the oldest open call of its call id, or at the end of
//! the turn. A `form` or an `approval` of an ask is answered here
//! (`ask::Panel`), by its keys or its buttons.

use gpui::{
    AnyElement, App, Application, Bounds, ClipboardItem, Context, FocusHandle, FontWeight,
    KeyDownEvent, ListAlignment, ListState, SharedString, Window, WindowBounds, WindowOptions, div,
    list, prelude::*, px, rgb, size,
};
use helyx_client_core::fold::State;
use helyx_client_core::frame::{LiveSession, SavedSession};
use helyx_client_core::json::Json;
use helyx_client_core::message::{Ask, Block, Message, Role};
use helyx_client_core::operation::Operation;
use helyx_client_core::records::{Record, Status};
use helyx_client_core::transcript::{Row, open_calls, rows};
use helyx_client_core::ui_block::MAX_BYTES;
use helyx_client_core::vocabulary::{
    Approval, Form, MAX_ARGUMENTS_BYTES, MAX_NAME_BYTES, MAX_TITLE_BYTES, UiBlock, View, head,
};
use helyx_desktop::ask::{FormState, Kind, Outcome, Panel};
use helyx_desktop::composer::{SendId, SendOutcome};
use helyx_desktop::controls::confirm_stop;
use helyx_desktop::input::{Focus, Input, Intent, Press};
use helyx_desktop::net::{self, Command, RequestLine, RequestState, Shared};
use helyx_desktop::records::{saved_only, texts};
use helyx_desktop::settings::Server;
use std::collections::HashMap;
use std::sync::mpsc::{Sender, channel, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// How often the window takes the changes of the network thread.
const REDRAW: Duration = Duration::from_millis(50);
const DIM: u32 = 0x9a9a9a;
const OK: u32 = 0x8fce8f;
const FAILED: u32 = 0xd06060;
const UNKNOWN: u32 = 0xc0a060;
/// The mark of a row that waits for the user.
const WAITING: u32 = 0xffc857;
/// The lines of the composer that the window shows, as the TUI.
const COMPOSER_LINES: usize = 8;
/// The request lines that the window shows; the rest are counted.
const SHOWN_REQUESTS: usize = 4;
/// The room of the body of an ask, in pixels, before it scrolls.
const ASK_HEIGHT: f32 = 420.;

/// One item of the transcript list.
#[derive(Clone)]
enum Item {
    Text(SharedString, u32),
    /// A UI block, with the line of an ask: this window answers the oldest
    /// open ask that it reads, and the others wait for it.
    Block {
        block: UiBlock,
        note: Option<&'static str>,
    },
}

struct Desktop {
    shared: Arc<Mutex<Shared>>,
    commands: Sender<Command>,
    transcript: ListState,
    input: Input,
    /// The live row whose **stop** was clicked once, and when: a second click
    /// on the same row inside `STOP_CONFIRM` sends the stop. A click
    /// elsewhere clears it.
    armed: Option<(String, Instant)>,
    /// The number of the `stop` of a row whose outcome asks for a fresh live
    /// list on a server with no Hub: a stopped session leaves the live list,
    /// and that server sends no live list of its own. With a records feed the
    /// change comes as a record frame, and no list is asked again.
    stop_send: Option<SendId>,
    /// Whether a stop was answered `ok` and the live list of a server with no
    /// Hub is due again.
    live_due: bool,
    /// The window holds the keys, so the root takes every press.
    focus: FocusHandle,
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
        cx.open_window(options, |window, cx| {
            let focus = cx.focus_handle();
            let view = cx.new(|cx| {
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
                    input: Input::new(),
                    armed: None,
                    stop_send: None,
                    live_due: false,
                    focus: focus.clone(),
                }
            });
            window.focus(&focus);
            view
        })
        .expect("a window");
        cx.activate(true);
    });
}

impl Desktop {
    /// The network thread changed the state.
    fn changed(&mut self, cx: &mut Context<Self>) {
        self.settle();
        self.default_cwd();
        self.refresh_live();
        cx.notify();
    }

    /// Asks the live sessions again after the server answered a `stop` with
    /// `ok` on a server with no Hub: the stopped session already left the
    /// live list, and no push carries the new one. With a records feed the
    /// feed sends the change, and no path sets `live_due`.
    fn refresh_live(&mut self) {
        if !self.live_due {
            return;
        }
        self.live_due = false;
        self.send_command(Command::Live);
    }

    /// The state of the network thread. A panic of the thread while it held
    /// the lock leaves its last state, which the window shows on.
    fn shared(&self) -> std::sync::MutexGuard<'_, Shared> {
        self.shared
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The session that the window follows and whether its turn runs.
    fn followed(&self) -> (Option<String>, bool) {
        let shared = self.shared();
        let followed = shared.followed.clone();
        let running = followed
            .as_deref()
            .and_then(|session| shared.client.state(session))
            .is_some_and(|state| state.running);
        (followed, running)
    }

    /// The state of the input that the network thread changed: the outcomes
    /// of the sends that the window waits for, and the asks of the followed
    /// session.
    fn settle(&mut self) {
        // The guard borrows the field of the shared state, and the input is
        // another field, so the states go in without a copy.
        let mut shared = self
            .shared
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let outcomes = std::mem::take(&mut shared.outcomes);
        let session = shared.followed.clone();
        let asks: &[Ask] = shared
            .followed
            .as_deref()
            .and_then(|session| shared.client.state(session))
            .map_or(&[], |state| &state.asks);
        // A stop whose reply asks for a fresh live list; a pending report
        // waits, and a failed one stops the wait. A records feed sends the
        // change itself, so only a server with no Hub asks again.
        if let Some(send) = self.stop_send
            // One read can hold the pending report and the reply: the last counts.
            && let Some((_, outcome)) = outcomes.iter().rev().find(|(id, _)| *id == send)
        {
            match outcome {
                SendOutcome::Pending => {}
                SendOutcome::Ok => {
                    self.stop_send = None;
                    if !shared.records {
                        self.live_due = true;
                    }
                }
                SendOutcome::Failed(_) => self.stop_send = None,
            }
        }
        self.input.settle_outcomes(&outcomes);
        self.input.sync(asks, session.as_deref());
    }

    /// The folder of a new session, until the user gives one: the newest
    /// saved session, else the first live one, else the first record of the
    /// feed.
    fn default_cwd(&mut self) {
        let cwd = {
            let shared = self.shared();
            (shared.saved.first())
                .map(|session| session.cwd.clone())
                .or_else(|| shared.live.first().map(|session| session.cwd.clone()))
                .or_else(|| {
                    (shared.client.records().rows().first()).map(|record| record.cwd.clone())
                })
        };
        if let Some(cwd) = cwd {
            self.input.default_cwd(&cwd);
        }
    }

    /// The items of the followed session.
    fn items(&self) -> Vec<Item> {
        let shared = self.shared();
        shared
            .followed
            .as_deref()
            .and_then(|session| shared.client.state(session))
            .map_or_else(Vec::new, items)
    }

    /// One key of the window: the abort, the ask, or the field that the keys
    /// act on.
    fn key(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let press = Press {
            key: &event.keystroke.key,
            shift: event.keystroke.modifiers.shift,
            alt: event.keystroke.modifiers.alt,
            platform: event.keystroke.modifiers.platform,
            control: event.keystroke.modifiers.control,
            text: event.keystroke.key_char.as_deref(),
        };
        self.settle();
        let (session, running) = self.followed();
        match self.input.press(press, session.as_deref(), running) {
            Intent::None => {}
            Intent::Send { send, operation } => self.send_operation(send, operation),
            Intent::Paste => {
                if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
                    self.input.paste(&text);
                }
            }
            Intent::Copy => {
                cx.write_to_clipboard(ClipboardItem::new_string(self.input.copy()));
            }
        }
        cx.notify();
    }

    /// Sends an operation of the window to the network thread. `send` is the
    /// number of a send of the composer or the answer of an ask, whose
    /// outcome settles it. A channel that the stopped thread dropped refuses
    /// the command: the input settles its number as failed, so the composer
    /// edits again and the ask shows again.
    fn send_operation(&mut self, send: Option<SendId>, operation: Operation) {
        let sent = self.commands.send(Command::Operation { send, operation });
        self.input.settle_refused(send, sent);
    }

    /// Sends an operation that no send of the composer numbers.
    fn send(&mut self, operation: Operation) {
        self.send_operation(None, operation);
    }

    /// The `set_model` of the ref in the field, from a click: the same path as
    /// Enter in the field.
    fn model(&mut self, session: Option<&str>) {
        if let Intent::Send { send, operation } = self.input.set_model(session) {
            self.send_operation(send, operation);
        }
    }

    /// The `compact` of the composer text, from a click: a numbered send, so
    /// `ok` empties the composer as a send does.
    fn compact(&mut self, session: Option<&str>) {
        if let Intent::Send { send, operation } = self.input.compact(session) {
            self.send_operation(send, operation);
        }
    }

    /// Hands a command with no send number to the network thread, and tells
    /// the user when the stopped thread's channel refuses it.
    fn send_command(&mut self, command: Command) {
        let sent = self.commands.send(command);
        self.input.settle_refused(None, sent);
    }

    /// The answer of the open ask, from a click: the same path as the keys.
    fn answer(&mut self, answer: Json, cx: &mut Context<Self>) {
        let session = self.followed().0;
        if let Intent::Send { send, operation } = self.input.answer(session.as_deref(), answer) {
            self.send_operation(send, operation);
        }
        cx.notify();
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
        place(shown.call_id.as_deref(), Item::Block { block, note: None });
    }
    // The window answers the oldest open ask that it reads; a later one
    // waits for it, and one that it cannot read waits for another client.
    let answering = Panel::answering(&state.asks);
    for ask in &state.asks {
        if let Some(block) = ask.block() {
            let note = Panel::note(ask, answering);
            place(Some(&ask.call_id), Item::Block { block, note });
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
                note: None,
            }));
        }
        items.extend(under.remove(&at).unwrap_or_default());
    }
    if let Some(partial) = &state.partial {
        items.push(Item::Text(text(partial).into(), DIM));
    }
    items.extend(end);
    items.extend(
        (state.notices.iter()).map(|n| Item::Text(SharedString::from(format!("✕ {n}")), FAILED)),
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
            UNKNOWN,
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
        self.settle();
        self.default_cwd();
        let (
            records_feed,
            record_rows,
            records_more,
            live,
            followed,
            line,
            running,
            saved,
            saved_next,
            requests,
        ) = {
            let shared = self.shared();
            let state = shared
                .followed
                .as_deref()
                .and_then(|session| shared.client.state(session));
            // A follow that waits or is held says why, derived on read.
            let line = shared
                .followed
                .as_deref()
                .and_then(|session| net::follow_line(session, &shared.client.follow(session)?))
                .unwrap_or_else(|| shared.line.clone());
            (
                shared.records,
                shared.client.records().rows().to_vec(),
                shared.client.records().more(),
                shared.live.clone(),
                shared.followed.clone(),
                line,
                state.is_some_and(|state| state.running),
                shared.saved.clone(),
                shared.saved_next.clone(),
                shared.requests.clone(),
            )
        };
        // The count of the list and the rows that it draws are one snapshot.
        let shown = self.items();
        if shown.len() != self.transcript.item_count() {
            self.transcript.reset(shown.len());
        }
        let asked = self.input.ask.clone();
        div()
            .id("window")
            .flex()
            .size_full()
            .bg(rgb(0x1e1e24))
            .text_color(rgb(0xdddddd))
            .track_focus(&self.focus)
            .on_key_down(
                cx.listener(|this, event: &KeyDownEvent, window, cx| this.key(event, window, cx)),
            )
            // Any click that the stop control does not take clears its armed
            // state.
            .on_click(cx.listener(|this, _, _, cx| {
                if this.armed.take().is_some() {
                    cx.notify();
                }
            }))
            .child(self.sidebar(
                Sidebar {
                    feed: records_feed,
                    records: &record_rows,
                    more: records_more,
                    live: &live,
                    saved: &saved,
                    saved_next: saved_next.as_deref(),
                    followed: followed.as_deref(),
                },
                cx,
            ))
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
                            Item::Block { block, note } => ui_block(block, *note),
                        })
                        .flex_1(),
                    )
                    .child(self.status(&requests))
                    .child(match &asked {
                        Some(panel) => self.ask_panel(panel, cx),
                        None => {
                            // The model ref and the two controls of the
                            // followed session sit above its composer.
                            let mut column = div().flex().flex_col();
                            if followed.is_some() {
                                column = column.child(self.controls(cx));
                            }
                            column.child(self.composer(running, cx)).into_any_element()
                        }
                    }),
            )
    }
}

/// What a click on a row does.
enum Click {
    /// Follow the session of the row.
    Follow(String),
    /// Resume the stopped session of the row: its reply follows it.
    Resume(String),
}

/// The state that the left column draws, as one snapshot.
struct Sidebar<'a> {
    /// Whether the connection has a records feed.
    feed: bool,
    records: &'a [Record],
    more: bool,
    live: &'a [LiveSession],
    saved: &'a [SavedSession],
    saved_next: Option<&'a str>,
    followed: Option<&'a str>,
}

impl Desktop {
    fn sidebar(&self, state: Sidebar<'_>, cx: &mut Context<Self>) -> impl IntoElement {
        let Sidebar {
            feed,
            records,
            more,
            live,
            saved,
            saved_next,
            followed,
        } = state;
        // The core holds the order of the feed: the window draws it as it
        // comes.
        let rows: Vec<AnyElement> = if feed {
            (records.iter())
                .map(|record| {
                    let id = record.session.clone();
                    let chosen = followed == Some(id.as_str());
                    let armed = self.armed.as_ref().is_some_and(|(row, _)| row == &id);
                    let stop = (record.status != Status::Stopped)
                        .then(|| self.stop_control(&id, armed, cx));
                    let click = match record.status {
                        Status::Stopped => Click::Resume(id.clone()),
                        _ => Click::Follow(id.clone()),
                    };
                    let texts = texts(record, records);
                    self.row_view(
                        format!("record-{id}"),
                        texts.title,
                        Some(texts.detail),
                        texts.parent,
                        if texts.waiting { WAITING } else { 0xffffff },
                        chosen,
                        stop,
                        click,
                        cx,
                    )
                    .into_any_element()
                })
                .collect()
        } else {
            (live.iter())
                .map(|session| {
                    let id = session.id.clone();
                    let chosen = followed == Some(id.as_str());
                    let armed = self.armed.as_ref().is_some_and(|(row, _)| row == &id);
                    let stop = Some(self.stop_control(&id, armed, cx));
                    self.row_view(
                        format!("live-{id}"),
                        format!("{} · {}", session.cwd, session.model),
                        None,
                        None,
                        0xdddddd,
                        chosen,
                        stop,
                        Click::Follow(id),
                        cx,
                    )
                    .into_any_element()
                })
                .collect()
        };
        // With a feed a session shows in one list only.
        let shown: Vec<&SavedSession> = match feed {
            true => saved_only(saved, records),
            false => saved.iter().collect(),
        };
        let saved_rows: Vec<AnyElement> = (shown.into_iter())
            .map(|session| {
                let id = session.id.clone();
                self.row_view(
                    format!("saved-{id}"),
                    session.prompt.clone(),
                    Some(session.cwd.clone()),
                    None,
                    0xdddddd,
                    false,
                    None,
                    Click::Resume(id),
                    cx,
                )
                .into_any_element()
            })
            .collect();
        let records_more = (feed && more).then(|| {
            div().px_2().text_color(rgb(DIM)).child(
                "the owner has more sessions than this list shows; the saved list below holds them",
            )
        });
        let more = saved_next.map(|next| {
            let next = next.to_owned();
            div()
                .id("saved-more")
                .p_2()
                .cursor_pointer()
                .text_color(rgb(DIM))
                .child("more sessions…")
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.send_command(Command::Saved {
                        after: Some(next.clone()),
                    });
                    cx.notify();
                }))
        });
        let cwd = self.input.cwd.display();
        let cwd_color = match self.input.focus {
            Focus::Cwd => 0xffffff,
            _ => DIM,
        };
        div()
            .flex()
            .flex_col()
            .w(px(280.))
            .border_r_1()
            .border_color(rgb(0x3a3a3a))
            .child(dim_row(if feed { "sessions" } else { "live" }))
            .children(rows)
            .when_some(records_more, |d, line| d.child(line))
            .child(dim_row("saved"))
            .child(
                div()
                    .id("saved-list")
                    .flex()
                    .flex_col()
                    .flex_1()
                    .overflow_y_scroll()
                    .children(saved_rows)
                    .when_some(more, |d, more| d.child(more)),
            )
            .child(
                div()
                    .p_2()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .border_t_1()
                    .border_color(rgb(0x3a3a3a))
                    .child(dim("new session in"))
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .items_center()
                            .child(
                                div()
                                    .id("cwd")
                                    .flex_1()
                                    .p_1()
                                    .bg(rgb(0x26262e))
                                    .text_color(rgb(cwd_color))
                                    .font_family("Menlo")
                                    .child(cwd)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.input.focus = Focus::Cwd;
                                        cx.notify();
                                    })),
                            )
                            .child(
                                div()
                                    .id("start")
                                    .px_2()
                                    .py_1()
                                    .rounded_md()
                                    .bg(rgb(0x2f4a2f))
                                    .cursor_pointer()
                                    .child("start")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        if let Some(start) = this.input.start() {
                                            this.send(start);
                                        }
                                        cx.notify();
                                    })),
                            ),
                    )
                    .child(
                        div()
                            .id("refresh-saved")
                            .p_1()
                            .cursor_pointer()
                            .text_color(rgb(DIM))
                            .child("refresh saved sessions")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.send_command(Command::Saved { after: None });
                                cx.notify();
                            })),
                    ),
            )
    }

    /// One row of the left column: the lines of `title`, `detail`, and
    /// `parent`, the highlight of the followed row, and the control of the
    /// stop when the row has one. A click does `click`.
    #[allow(clippy::too_many_arguments)]
    fn row_view(
        &self,
        key: String,
        title: String,
        detail: Option<String>,
        parent: Option<String>,
        color: u32,
        chosen: bool,
        stop: Option<AnyElement>,
        click: Click,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let mut lines = div()
            .flex()
            .flex_col()
            .gap_1()
            .flex_1()
            .child(div().text_color(rgb(color)).child(title));
        // The parent of a child is the second line, dim; the folder, the
        // model, and the status follow.
        if let Some(parent) = parent {
            lines = lines.child(dim(&parent));
        }
        if let Some(detail) = detail {
            lines = lines.child(dim(&detail));
        }
        let mut row = div()
            .id(SharedString::from(key))
            .p_2()
            .flex()
            .gap_2()
            .items_center()
            .cursor_pointer()
            .when(chosen, |d| d.bg(rgb(0x3a3a4a)))
            .child(lines);
        if let Some(stop) = stop {
            row = row.child(stop);
        }
        row.on_click(cx.listener(move |this, _, _, cx| {
            match &click {
                Click::Follow(id) => this.send_command(Command::Follow(id.clone())),
                Click::Resume(id) => this.send(Operation::resume(id)),
            }
            cx.notify();
        }))
    }

    /// The **stop** control of a row: one click arms it as **stop?**, and a
    /// second click inside `controls::STOP_CONFIRM` sends the stop.
    fn stop_control(&self, session: &str, armed: bool, cx: &mut Context<Self>) -> AnyElement {
        let stop_row = session.to_owned();
        div()
            .id(SharedString::from(format!("stop-{stop_row}")))
            .px_1()
            .rounded_md()
            .bg(rgb(0x5a3030))
            .cursor_pointer()
            .child(if armed { "stop?" } else { "stop" })
            .on_click(cx.listener(move |this, _, _, cx| {
                // The stop control takes the click, so the row below does not
                // follow it and the root does not clear it.
                cx.stop_propagation();
                let now = Instant::now();
                match confirm_stop(this.armed.as_ref(), &stop_row, now) {
                    true => {
                        this.armed = None;
                        let send = this.input.send_number();
                        this.stop_send = Some(send);
                        this.send_operation(Some(send), Operation::stop(&stop_row));
                    }
                    false => this.armed = Some((stop_row.clone(), now)),
                }
                cx.notify();
            }))
            .into_any_element()
    }

    fn status(&self, requests: &[RequestLine]) -> gpui::Div {
        use helyx_client_core::usage::{Level, context_percent, cost_text, level, tokens_text};

        // The usage of the followed session, as its fold holds it.
        let (usage, context, model) = {
            let shared = self.shared();
            match shared
                .followed
                .as_deref()
                .and_then(|session| shared.client.state(session))
            {
                Some(state) => (
                    state.usage.clone(),
                    state.context.clone(),
                    state.model.clone(),
                ),
                None => (Default::default(), None, String::new()),
            }
        };
        let prompt = usage
            .input
            .saturating_add(usage.cache_read)
            .saturating_add(usage.cache_write);
        let mut parts: Vec<(String, u32)> = Vec::new();
        if prompt.saturating_add(usage.output) > 0 {
            parts.push((
                format!(
                    "in {} out {}",
                    tokens_text(prompt),
                    tokens_text(usage.output)
                ),
                DIM,
            ));
        }
        if prompt > 0 {
            let percent = u128::from(usage.cache_read) * 100 / u128::from(prompt);
            parts.push((format!("cache {percent}%"), DIM));
        }
        if let Some(cost) = cost_text(&usage) {
            parts.push((cost, DIM));
        }
        if let Some(context) = context.as_ref()
            && let Some(percent) = context_percent(context, &model)
        {
            // The display caps the percent; the level follows the exact one.
            let text = if percent > 999 {
                ">999%".to_owned()
            } else {
                format!("{percent}%")
            };
            let color = match level(percent) {
                Level::Normal => DIM,
                Level::Warn => 0xffb000,
                Level::Bad => FAILED,
            };
            parts.push((text, color));
        }
        let followed = (!parts.is_empty()).then(|| {
            div()
                .flex()
                .gap_1()
                .px_2()
                .text_size(px(11.))
                .text_color(rgb(DIM))
                .children(
                    parts
                        .into_iter()
                        .map(|(text, color)| div().text_color(rgb(color)).child(text)),
                )
        });

        let shown = &requests[requests.len().saturating_sub(SHOWN_REQUESTS)..];
        let older = requests.len() - shown.len();
        div()
            .flex()
            .flex_col()
            .gap_1()
            .px_2()
            .children((shown.iter()).map(|line| {
                let color = match line.state {
                    RequestState::Pending => DIM,
                    RequestState::Ok => OK,
                    RequestState::Error { .. } => FAILED,
                    RequestState::Unknown => UNKNOWN,
                };
                div()
                    .text_color(rgb(color))
                    .text_size(px(11.))
                    .child(line.text())
            }))
            .when_some(followed, |d, row| d.child(row))
            .when_some(self.input.notice.as_ref(), |d, notice| {
                d.child(
                    div()
                        .text_color(rgb(FAILED))
                        .text_size(px(11.))
                        .child(notice.clone()),
                )
            })
            .when(older > 0, |d| {
                d.child(dim(&format!("{older} earlier requests")))
            })
    }

    /// The composer, and the abort of a running turn.
    fn composer(&self, running: bool, cx: &mut Context<Self>) -> impl IntoElement {
        let (text, cut) = self.input.composer.text.window(COMPOSER_LINES);
        div()
            .flex()
            .flex_col()
            .gap_1()
            .p_2()
            .border_t_1()
            .border_color(rgb(0x3a3a3a))
            .when(running, |d| {
                d.child(
                    div()
                        .flex()
                        .gap_2()
                        .items_center()
                        .child(dim("Enter steers · Option+Enter follows up"))
                        .child(
                            div()
                                .id("abort")
                                .px_2()
                                .py_1()
                                .rounded_md()
                                .cursor_pointer()
                                .bg(rgb(0x5a3030))
                                .child("abort")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    if let Some(session) = this.followed().0 {
                                        this.send(Operation::abort(&session));
                                    }
                                    cx.notify();
                                })),
                        ),
                )
            })
            .child(
                div()
                    .id("composer")
                    .p_2()
                    .rounded_md()
                    .bg(rgb(0x26262e))
                    .font_family("Menlo")
                    .text_size(px(13.))
                    .max_h(px(20. * (COMPOSER_LINES as f32 + 1.)))
                    .overflow_hidden()
                    .cursor_text()
                    .when(cut, |d| d.child(dim("…")))
                    .child(text)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.input.focus = Focus::Composer;
                        cx.notify();
                    })),
            )
            .child(dim(if running {
                "Shift+Enter a new line · Esc or Cmd+. aborts the turn · Cmd+V pastes"
            } else {
                "Enter sends · Shift+Enter a new line · Cmd+V pastes"
            }))
    }

    /// The controls of the followed session above its composer: the model ref
    /// of its next turn, a switch to it, and a compaction with the composer
    /// text.
    fn controls(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let model_color = match self.input.focus {
            Focus::Model => 0xffffff,
            _ => DIM,
        };
        div()
            .flex()
            .gap_2()
            .items_center()
            .px_2()
            .py_1()
            .border_t_1()
            .border_color(rgb(0x3a3a3a))
            .child(
                div()
                    .id("model-ref")
                    .flex_1()
                    .p_1()
                    .bg(rgb(0x26262e))
                    .text_color(rgb(model_color))
                    .font_family("Menlo")
                    .child(self.input.model.display())
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.input.focus = Focus::Model;
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .id("model")
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .bg(rgb(0x2f4a2f))
                    .cursor_pointer()
                    .child("model")
                    .on_click(cx.listener(|this, _, _, cx| {
                        let session = this.followed().0;
                        this.model(session.as_deref());
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .id("compact")
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .bg(rgb(0x2f4a2f))
                    .cursor_pointer()
                    .child("compact")
                    .on_click(cx.listener(|this, _, _, cx| {
                        let session = this.followed().0;
                        this.compact(session.as_deref());
                        cx.notify();
                    })),
            )
    }

    /// The ask that takes the keys, in the place of the composer: a form with
    /// its options and its Other line, or an approval with Allow and Deny.
    fn ask_panel(&self, panel: &Panel, cx: &mut Context<Self>) -> AnyElement {
        let body = match &panel.kind {
            Kind::Form(form) => self.form(panel, form, cx),
            Kind::Approval(approval) => self.approval(panel, approval, cx),
        };
        div()
            .flex()
            .flex_col()
            .gap_1()
            .p_2()
            .border_t_1()
            .border_color(rgb(0x3a3a4a))
            .child(
                div()
                    .font_weight(FontWeight::BOLD)
                    .child(head(&panel.block.text, MAX_TITLE_BYTES).0.to_owned()),
            )
            // A form of four questions can be taller than the window: the
            // body scrolls, and the window keeps a row for the transcript.
            .child(
                div()
                    .id("ask-body")
                    .flex()
                    .flex_col()
                    .gap_1()
                    .max_h(px(ASK_HEIGHT))
                    .overflow_y_scroll()
                    .child(body),
            )
            .when_some(panel.error().map(str::to_owned), |d, error| {
                d.child(div().text_color(rgb(FAILED)).child(error))
            })
            .into_any_element()
    }

    fn form(&self, panel: &Panel, form: &FormState, cx: &mut Context<Self>) -> gpui::Div {
        let current = form.current;
        let questions: Vec<AnyElement> = (form.questions.iter().enumerate())
            .map(|(at, question)| {
                // The marks belong to the current question only.
                let marks = panel.marked(at);
                let options = (question.options.iter().enumerate()).map(|(option, choice)| {
                    // A single pick has no mark: it is the option under the
                    // cursor at Enter.
                    let mark = match (question.multi_select, marks.get(option) == Some(&true)) {
                        (true, true) => "☑",
                        (true, false) => "☐",
                        (false, _) => "○",
                    };
                    let cursor = at == current && form.option == option;
                    div()
                        .id(SharedString::from(format!("ask-{at}-{option}")))
                        .flex()
                        .gap_2()
                        .px_1()
                        .rounded_md()
                        .when(cursor, |d| d.bg(rgb(0x3a3a4a)))
                        .cursor_pointer()
                        .child(format!("{mark} {}", choice.label))
                        .child(dim(&choice.description))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(panel) = this.input.ask.as_mut()
                                && let Outcome::Answer(answer) = panel.choose(at, option)
                            {
                                this.answer(answer, cx);
                            }
                            cx.notify();
                        }))
                });
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                div()
                                    .px_1()
                                    .bg(rgb(0x3a3a4a))
                                    .font_weight(FontWeight::BOLD)
                                    .child(question.header.clone()),
                            )
                            .child(question.question.clone())
                            .when(at != current, |d| d.text_color(rgb(DIM))),
                    )
                    .children(options)
                    .when(at == current, |d| {
                        // The Other line is a cursor position after the
                        // options, as in the TUI.
                        let on_other = form.option == question.options.len();
                        d.child(
                            div()
                                .flex()
                                .gap_2()
                                .px_1()
                                .rounded_md()
                                .when(on_other, |d| d.bg(rgb(0x3a3a4a)))
                                .child(dim("other"))
                                .child(div().font_family("Menlo").child(
                                    panel.other().map_or(String::new(), |text| text.display()),
                                )),
                        )
                    })
                    .into_any_element()
            })
            .collect();
        div()
            .flex()
            .flex_col()
            .gap_2()
            .children(questions)
            .child(dim(if form.current + 1 < form.questions.len() {
                "Enter answers this question · ↑↓ move · Space marks"
            } else {
                "Enter sends the answers · ↑↓ move · Space marks"
            }))
    }

    fn approval(&self, panel: &Panel, approval: &Approval, cx: &mut Context<Self>) -> gpui::Div {
        let answer = |allow: bool| {
            let answer = panel.approval(allow);
            move |this: &mut Desktop,
                  _: &gpui::ClickEvent,
                  _: &mut Window,
                  cx: &mut Context<Desktop>| {
                this.answer(answer.clone(), cx);
                cx.notify();
            }
        };
        approval_body(&panel.block.text, approval).child(
            div()
                .flex()
                .gap_2()
                .child(
                    div()
                        .id("allow")
                        .px_2()
                        .py_1()
                        .rounded_md()
                        .bg(rgb(0x2f4a2f))
                        .cursor_pointer()
                        .child("Allow")
                        .on_click(cx.listener(answer(true))),
                )
                .child(
                    div()
                        .id("deny")
                        .px_2()
                        .py_1()
                        .rounded_md()
                        .bg(rgb(0x4a2f2f))
                        .cursor_pointer()
                        .child("Deny")
                        .on_click(cx.listener(answer(false))),
                ),
        )
    }
}

/// A UI block: a `form` and an `approval` natively, any other kind, and a
/// known kind whose fields the app cannot read, as its fallback text; a mark
/// when it was cut. `note` is the line of an ask: whether this window answers
/// it now, later, or not at all, since an ask that it cannot read stays open
/// for another client (ADR 0011 §4).
fn ui_block(block: &UiBlock, note: Option<&'static str>) -> AnyElement {
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
                .when_some(note, |d, note| d.child(dim(note))),
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
}

fn dim_row(title: &str) -> gpui::Div {
    div()
        .px_2()
        .pt_2()
        .text_color(rgb(DIM))
        .child(title.to_owned())
}

fn dim(text: &str) -> gpui::Div {
    div().text_color(rgb(DIM)).child(text.to_owned())
}
