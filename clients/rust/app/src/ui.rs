//! The window of the app on macOS (`docs/features/client-kit.md`, slice 4):
//! the live sessions of the server on the left, the transcript of the
//! followed one on the right. The rows come from `transcript::rows`; the
//! list draws only the rows in view.

use gpui::{
    App, Application, Bounds, Context, ListAlignment, ListState, SharedString, Window,
    WindowBounds, WindowOptions, div, list, prelude::*, px, rgb, size,
};
use helyx_client_core::message::{Block, Message, Role};
use helyx_client_core::transcript::{Row, rows};
use helyx_desktop::net::{self, Command, Shared};
use helyx_desktop::settings::Server;
use std::sync::mpsc::{Sender, channel, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How often the window takes the changes of the network thread.
const REDRAW: Duration = Duration::from_millis(50);

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

    /// The rows of the followed session, each as its text and its color.
    fn rows(&self) -> Vec<(SharedString, u32)> {
        let shared = self.shared();
        let Some(state) = shared
            .followed
            .as_deref()
            .and_then(|s| shared.client.state(s))
        else {
            return vec![];
        };
        let mut shown: Vec<(SharedString, u32)> = rows(&state.messages).iter().map(row).collect();
        if let Some(partial) = &state.partial {
            shown.push((text(partial).into(), 0x9a9a9a));
        }
        shown.extend(
            state
                .notices
                .iter()
                .map(|n| (SharedString::from(format!("✕ {n}")), 0xd06060)),
        );
        shown
    }
}

fn row(row: &Row<'_>) -> (SharedString, u32) {
    match row {
        Row::Message(m) if m.role == Role::User => (format!("› {}", text(m)).into(), 0xffffff),
        Row::Message(m) => (text(m).into(), 0xdddddd),
        Row::Call {
            call: Block::ToolCall { name, .. },
            result,
        } => {
            let shown = result.map_or("awaiting result".to_owned(), text);
            (format!("⏺ {name}\n{shown}").into(), 0x8fb8de)
        }
        Row::Call { .. } => unreachable!("a call row holds a tool call"),
        Row::Orphan(result) => (
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
            (
                shared.live.clone(),
                shared.followed.clone(),
                shared.line.clone(),
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
                        list(self.transcript.clone(), move |ix, _, _| {
                            let (text, color) = shown[ix].clone();
                            div()
                                .p_2()
                                .text_color(rgb(color))
                                .child(text)
                                .into_any_element()
                        })
                        .flex_1(),
                    ),
            )
    }
}
