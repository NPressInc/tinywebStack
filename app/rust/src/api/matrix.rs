use std::{
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Duration,
};

use anyhow::{anyhow, Context as _};
use crate::frb_generated::StreamSink;
use matrix_sdk::{
    authentication::matrix::MatrixSession as AuthMatrixSession,
    config::SyncSettings,
    deserialized_responses::{EncryptionInfo, TimelineEvent, TimelineEventKind},
    room::MessagesOptions,
    ruma::{
        api::error::ErrorKind,
        api::client::room::create_room,
        assign,
        events::room::{
            encryption::RoomEncryptionEventContent,
            member::{MembershipState, StrippedRoomMemberEvent, SyncRoomMemberEvent},
            message::{MessageType, RoomMessageEventContent, SyncRoomMessageEvent},
        },
        events::{AnySyncMessageLikeEvent, AnySyncTimelineEvent, InitialStateEvent, SyncMessageLikeEvent},
        serde::Raw,
        OwnedDeviceId, OwnedUserId, RoomId, UserId, uint,
    },
    reqwest::Certificate,
    sliding_sync::{SlidingSyncList, SlidingSyncMode, Version as SlidingSyncVersion},
    Client, Error as SdkError, Room, RoomMemberships, RoomState, SessionMeta, SessionTokens,
};
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;
use tracing::{info, warn};
use url::Url;

static TOKIO_RT: OnceLock<Runtime> = OnceLock::new();

fn runtime() -> &'static Runtime {
    TOKIO_RT.get_or_init(|| Runtime::new().expect("failed to build tokio runtime"))
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    let _ = runtime();
}

#[derive(Clone, Debug)]
pub struct RoomSummary {
    pub room_id: String,
    pub name: String,
    pub is_encrypted: bool,
    pub joined_members: u32,
    pub last_message: Option<String>,
    pub last_ts_ms: Option<i64>,
    pub unread: u64,
    pub is_direct: bool,
}

#[derive(Clone, Debug)]
pub struct TimelineMessage {
    pub event_id: String,
    pub sender: String,
    pub sender_display_name: Option<String>,
    pub body: String,
    pub ts_ms: i64,
    pub is_own: bool,
}

#[derive(Clone, Debug)]
pub struct RoomMemberInfo {
    pub user_id: String,
    pub display_name: Option<String>,
}

#[derive(Clone, Debug)]
pub struct IncomingMessage {
    pub room_id: String,
    pub sender: String,
    pub sender_display_name: Option<String>,
    pub body: String,
    pub event_id: String,
    pub was_encrypted: bool,
    pub ts_ms: i64,
    pub is_own: bool,
}

#[derive(Clone, Debug)]
pub enum SyncEvent {
    Message(IncomingMessage),
    RoomsChanged,
}

#[flutter_rust_bridge::frb(opaque)]
pub struct MatrixSession {
    client: Client,
    sync_stop: Arc<AtomicBool>,
    sync_task: Mutex<Option<JoinHandle<()>>>,
    handler_handles: Mutex<Vec<matrix_sdk::event_handler::EventHandlerHandle>>,
}

fn server_name_from_homeserver(homeserver_url: &str) -> anyhow::Result<String> {
    let url = Url::parse(homeserver_url).context("invalid homeserver URL")?;
    url.host_str()
        .map(|h| h.to_owned())
        .ok_or_else(|| anyhow!("homeserver URL has no host"))
}

fn mxid_from_username(username: &str, server_name: &str) -> String {
    if username.starts_with('@') {
        username.to_owned()
    } else {
        format!("@{}:{}", username, server_name)
    }
}

async fn build_client(
    homeserver_url: &str,
    store_dir: &str,
    ca_cert_pem: Option<String>,
) -> anyhow::Result<Client> {
    std::fs::create_dir_all(store_dir).context("create store_dir")?;

    let mut builder = Client::builder()
        .homeserver_url(homeserver_url)
        .sqlite_store(Path::new(store_dir), None);

    if let Some(pem) = ca_cert_pem {
        let cert = Certificate::from_pem(pem.as_bytes())
            .context("parse CA certificate PEM")?;
        builder = builder.add_root_certificates(vec![cert]);
    }

    builder.build().await.context("build matrix client")
}

fn map_send_error(err: SdkError) -> anyhow::Error {
    if matches!(err.client_api_error_kind(), Some(ErrorKind::Forbidden)) {
        let msg = err
            .as_client_api_error()
            .map(|e| e.to_string())
            .unwrap_or_else(|| "Forbidden".to_owned());
        return anyhow!("forbidden: {}", msg);
    }
    anyhow!(err)
}

async fn member_display_name(room: &Room, user_id: &UserId) -> Option<String> {
    room.get_member(user_id)
        .await
        .ok()
        .flatten()
        .and_then(|m| m.display_name().map(|s| s.to_owned()))
}

fn body_from_msgtype(msgtype: &MessageType) -> Option<String> {
    match msgtype {
        MessageType::Text(t) => Some(t.body.clone()),
        MessageType::Notice(n) => Some(n.body.clone()),
        MessageType::Emote(e) => Some(format!("*{}*", e.body)),
        _ => None,
    }
}

fn timeline_ts_ms(event: &TimelineEvent) -> i64 {
    event
        .timestamp
        .map(|t| t.get().into())
        .unwrap_or(0u64) as i64
}

fn parse_timeline_message(
    event: &TimelineEvent,
    own_user_id: &UserId,
    _room: &Room,
) -> Option<TimelineMessage> {
    let ts_ms = timeline_ts_ms(event);

    if matches!(event.kind, TimelineEventKind::UnableToDecrypt { .. }) {
        let event_id = event
            .event_id()
            .map(|id| id.to_string())
            .unwrap_or_default();
        let sender = event
            .raw()
            .get_field::<OwnedUserId>("sender")
            .ok()
            .flatten()
            .map(|u| u.to_string())
            .unwrap_or_default();
        let is_own = sender == own_user_id.to_string();
        return Some(TimelineMessage {
            event_id,
            sender,
            sender_display_name: None,
            body: "Encrypted message (not supported)".to_owned(),
            ts_ms,
            is_own,
        });
    }

    let Ok(parsed) = event.raw().deserialize() else {
        return None;
    };
    match parsed {
        AnySyncTimelineEvent::MessageLike(like) => match like {
            AnySyncMessageLikeEvent::RoomMessage(msg) => {
                let (sender, event_id, content) = match msg {
                    SyncMessageLikeEvent::Original(o) => {
                        (o.sender.clone(), o.event_id.to_string(), o.content.clone())
                    }
                    SyncMessageLikeEvent::Redacted(_) => return None,
                };
                let body = body_from_msgtype(&content.msgtype)?;
                Some(TimelineMessage {
                    event_id,
                    sender: sender.to_string(),
                    sender_display_name: None,
                    body,
                    ts_ms,
                    is_own: sender == *own_user_id,
                })
            }
            _ => None,
        },
        _ => None,
    }
}

async fn enrich_display_names(room: &Room, messages: Vec<TimelineMessage>) -> Vec<TimelineMessage> {
    let mut out = Vec::with_capacity(messages.len());
    for m in messages {
        let sender_id = UserId::parse(&m.sender).ok();
        let display = if let Some(uid) = sender_id.as_ref() {
            member_display_name(room, uid).await
        } else {
            None
        };
        out.push(TimelineMessage {
            sender_display_name: display,
            ..m
        });
    }
    out
}

pub async fn restore_session(
    homeserver_url: String,
    user_id: String,
    device_id: String,
    access_token: String,
    store_dir: String,
    ca_cert_pem: Option<String>,
) -> anyhow::Result<MatrixSession> {
    let user_id = UserId::parse(&user_id).context("parse user_id")?;
    let device_id: OwnedDeviceId = device_id.into();

    let client = build_client(&homeserver_url, &store_dir, ca_cert_pem).await?;

    let session = AuthMatrixSession {
        meta: SessionMeta {
            user_id: user_id.clone(),
            device_id: device_id.clone(),
        },
        tokens: SessionTokens {
            access_token,
            refresh_token: None,
        },
    };
    client.restore_session(session).await.context("restore_session")?;

    Ok(MatrixSession {
        client,
        sync_stop: Arc::new(AtomicBool::new(false)),
        sync_task: Mutex::new(None),
        handler_handles: Mutex::new(Vec::new()),
    })
}

pub async fn login(
    homeserver_url: String,
    username: String,
    password: String,
    store_dir: String,
    ca_cert_pem: Option<String>,
    device_name: String,
) -> anyhow::Result<MatrixSession> {
    let server_name = server_name_from_homeserver(&homeserver_url)?;
    let mxid = mxid_from_username(&username, &server_name);

    let client = build_client(&homeserver_url, &store_dir, ca_cert_pem).await?;

    client
        .matrix_auth()
        .login_username(&mxid, &password)
        .initial_device_display_name(&device_name)
        .send()
        .await
        .context("matrix login")?;

    Ok(MatrixSession {
        client,
        sync_stop: Arc::new(AtomicBool::new(false)),
        sync_task: Mutex::new(None),
        handler_handles: Mutex::new(Vec::new()),
    })
}

impl MatrixSession {
    pub fn user_id(&self) -> String {
        self.client
            .user_id()
            .map(|u| u.to_string())
            .unwrap_or_default()
    }

    pub async fn sync_once(&self) -> anyhow::Result<()> {
        self.client
            .sync_once(SyncSettings::default().timeout(Duration::from_secs(30)))
            .await
            .context("sync_once")?;
        Ok(())
    }

    pub async fn list_rooms(&self) -> anyhow::Result<Vec<RoomSummary>> {
        let own_user = self
            .client
            .user_id()
            .ok_or_else(|| anyhow!("not logged in"))?;

        let mut out = Vec::new();
        for room in self.client.joined_rooms() {
            let room_id = room.room_id().to_string();
            let is_direct = room.is_direct().await.unwrap_or(false);
            let name = if is_direct {
                direct_room_display_name(&room, &own_user).await
            } else {
                room.name()
                    .map(|s| s.to_owned())
                    .unwrap_or_else(|| room_id.clone())
            };
            let is_encrypted = room
                .latest_encryption_state()
                .await
                .map(|s| s.is_encrypted())
                .unwrap_or(false);
            let joined_members = room.active_members_count().min(u32::MAX as u64) as u32;
            let unread = room.num_unread_notifications();

            let mut last_message = None;
            let mut last_ts_ms = None;
            let mut options = MessagesOptions::backward();
            options.limit = uint!(1);
            if let Ok(msgs) = room.messages(options).await {
                if let Some(ev) = msgs.chunk.first() {
                    if let Some(tm) = parse_timeline_message(ev, &own_user, &room) {
                        last_message = Some(tm.body);
                        last_ts_ms = Some(tm.ts_ms);
                    }
                }
            }

            out.push(RoomSummary {
                room_id,
                name,
                is_encrypted,
                joined_members,
                last_message,
                last_ts_ms,
                unread,
                is_direct,
            });
        }
        out.sort_by(|a, b| {
            b.last_ts_ms
                .unwrap_or(0)
                .cmp(&a.last_ts_ms.unwrap_or(0))
        });
        Ok(out)
    }

    pub async fn room_timeline(
        &self,
        room_id: String,
        limit: u32,
    ) -> anyhow::Result<Vec<TimelineMessage>> {
        let own_user = self
            .client
            .user_id()
            .ok_or_else(|| anyhow!("not logged in"))?;
        let id = RoomId::parse(&room_id).context("parse room_id")?;
        let room = self
            .client
            .get_room(&id)
            .ok_or_else(|| anyhow!("room not in local store: {room_id}"))?;

        let mut options = MessagesOptions::backward();
        options.limit = matrix_sdk::ruma::UInt::new(limit as u64).unwrap_or(uint!(50));
        let msgs = room.messages(options).await.context("room messages")?;

        let mut parsed: Vec<TimelineMessage> = msgs
            .chunk
            .iter()
            .filter_map(|ev| parse_timeline_message(ev, &own_user, &room))
            .collect();
        parsed.reverse();
        Ok(enrich_display_names(&room, parsed).await)
    }

    pub async fn room_members(&self, room_id: String) -> anyhow::Result<Vec<RoomMemberInfo>> {
        let id = RoomId::parse(&room_id).context("parse room_id")?;
        let room = self
            .client
            .get_room(&id)
            .ok_or_else(|| anyhow!("room not in local store: {room_id}"))?;
        let members = room.members(RoomMemberships::ACTIVE).await.context("room members")?;
        Ok(members
            .iter()
            .map(|m| RoomMemberInfo {
                user_id: m.user_id().to_string(),
                display_name: m.display_name().map(|s| s.to_owned()),
            })
            .collect())
    }

    pub async fn create_direct_chat(&self, user_id: String) -> anyhow::Result<String> {
        let uid = UserId::parse(&user_id).context("parse user_id")?;
        if let Some(room) = self.client.get_dm_room(&uid) {
            return Ok(room.room_id().to_string());
        }

        let request = assign!(create_room::v3::Request::new(), {
            invite: vec![uid.to_owned()],
            is_direct: true,
            preset: Some(create_room::v3::RoomPreset::PrivateChat),
            initial_state: vec![] as Vec<Raw<matrix_sdk::ruma::events::AnyInitialStateEvent>>,
        });
        let room = self.client.create_room(request).await.context("create_direct_chat")?;
        Ok(room.room_id().to_string())
    }

    pub async fn create_room(
        &self,
        name: String,
        invite_user_ids: Vec<String>,
        encrypted: bool,
    ) -> anyhow::Result<String> {
        let invite: Vec<OwnedUserId> = invite_user_ids
            .iter()
            .map(|id| UserId::parse(id).map_err(|e| anyhow!("invalid user id {id}: {e}")))
            .collect::<Result<Vec<_>, _>>()?;

        let mut initial_state: Vec<Raw<matrix_sdk::ruma::events::AnyInitialStateEvent>> = vec![];
        if encrypted {
            initial_state.push(
                InitialStateEvent::with_empty_state_key(
                    RoomEncryptionEventContent::with_recommended_defaults(),
                )
                .to_raw_any(),
            );
        }

        let preset = if encrypted {
            create_room::v3::RoomPreset::TrustedPrivateChat
        } else {
            create_room::v3::RoomPreset::PrivateChat
        };
        let request = assign!(create_room::v3::Request::new(), {
            name: Some(name),
            invite,
            preset: Some(preset),
            initial_state,
        });

        let room = self.client.create_room(request).await.context("create_room")?;
        Ok(room.room_id().to_string())
    }

    pub async fn join_room(&self, room_id: String) -> anyhow::Result<()> {
        let id = RoomId::parse(&room_id).context("parse room_id")?;
        if let Some(room) = self.client.get_room(&id) {
            room.join().await.context("join via invited room")?;
            return Ok(());
        }
        self.client
            .join_room_by_id(&id)
            .await
            .context("join_room_by_id")?;
        Ok(())
    }

    pub async fn send_text(&self, room_id: String, body: String) -> anyhow::Result<String> {
        let id = RoomId::parse(&room_id).context("parse room_id")?;
        let room = self
            .client
            .get_room(&id)
            .ok_or_else(|| anyhow!("room not in local store: {room_id}"))?;
        let result = room
            .send(RoomMessageEventContent::text_plain(body))
            .await
            .map_err(map_send_error)?;
        Ok(result.response.event_id.to_string())
    }

    pub fn start_sync(&self, sink: StreamSink<SyncEvent>) {
        self.stop_sync();

        let own_user = self.user_id();
        let client = self.client.clone();
        let stop = self.sync_stop.clone();
        stop.store(false, Ordering::SeqCst);

        let sink_handler = sink.clone();
        let mut handles = Vec::new();

        handles.push(client.add_event_handler(
            move |ev: SyncRoomMessageEvent,
                  room: Room,
                  encryption_info: Option<EncryptionInfo>| {
                let sink = sink_handler.clone();
                let own_user = own_user.clone(); // mxid string
                async move {
                    let Some(original) = ev.as_original() else {
                        return;
                    };
                    let was_encrypted = encryption_info.is_some();
                    let body = if was_encrypted {
                        "Encrypted message (not supported)".to_owned()
                    } else {
                        match &original.content.msgtype {
                            MessageType::Text(text) => text.body.clone(),
                            MessageType::Notice(n) => n.body.clone(),
                            MessageType::Emote(e) => format!("*{}*", e.body),
                            _ => return,
                        }
                    };
                    let sender = original.sender.clone();
                    let display = member_display_name(&room, &sender).await;
                    let is_own = own_user == sender.to_string();
                    let ts_ms = u64::from(original.origin_server_ts.get()) as i64;
                    let msg = IncomingMessage {
                        room_id: room.room_id().to_string(),
                        sender: sender.to_string(),
                        sender_display_name: display,
                        body,
                        event_id: original.event_id.to_string(),
                        was_encrypted,
                        ts_ms,
                        is_own,
                    };
                    let _ = sink.add(SyncEvent::Message(msg));
                }
            },
        ));

        handles.push(client.add_event_handler(
            |ev: SyncRoomMemberEvent, room: Room| async move {
                if room.state() == RoomState::Invited
                    && *ev.membership() == MembershipState::Invite
                {
                    if let Err(e) = room.join().await {
                        warn!("auto-join (member event) failed: {e:?}");
                    }
                }
            },
        ));

        handles.push(client.add_event_handler(
            |_ev: StrippedRoomMemberEvent, room: Room| async move {
                if room.state() == RoomState::Invited {
                    if let Err(e) = room.join().await {
                        warn!("auto-join (stripped invite) failed: {e:?}");
                    }
                }
            },
        ));

        *self.handler_handles.lock().expect("handler lock") = handles;

        let sink_loop = sink.clone();
        let handle = runtime().spawn(async move {
            let settings = SyncSettings::default().timeout(Duration::from_secs(30));
            while !stop.load(Ordering::SeqCst) {
                match client.sync_once(settings.clone()).await {
                    Ok(_) => {
                        let _ = sink_loop.add(SyncEvent::RoomsChanged);
                    }
                    Err(e) => {
                        warn!("background sync error: {e:?}");
                        tokio::time::sleep(Duration::from_secs(2)).await;
                    }
                }
            }
            info!("matrix background sync stopped");
        });
        *self.sync_task.lock().expect("sync task lock") = Some(handle);
    }

    pub fn stop_sync(&self) {
        self.sync_stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.sync_task.lock().expect("sync task lock").take() {
            handle.abort();
        }
        let mut guard = self.handler_handles.lock().expect("handler lock");
        let handles: Vec<_> = guard.drain(..).collect();
        for h in handles {
            self.client.remove_event_handler(h);
        }
    }

    pub async fn try_sliding_sync(&self) -> String {
        let versions = self.client.available_sliding_sync_versions().await;
        let native_supported = versions
            .iter()
            .any(|v| matches!(v, SlidingSyncVersion::Native));

        if !native_supported {
            return format!(
                "MSC4186 native sliding sync: not advertised (versions={versions:?})"
            );
        }

        let sync_result = async {
            let sliding = self
                .client
                .sliding_sync("spike-ss")?
                .version(SlidingSyncVersion::Native)
                .add_list(
                    SlidingSyncList::builder("rooms").sync_mode(
                        SlidingSyncMode::new_selective().add_range(0..=9),
                    ),
                )
                .build()
                .await?;
            sliding.sync_once().await?;
            Ok::<(), anyhow::Error>(())
        }
        .await;

        match sync_result {
            Ok(()) => format!(
                "MSC4186 native sliding sync: supported; basic room-list sync_once: OK"
            ),
            Err(e) => format!(
                "MSC4186 native sliding sync: supported; basic room-list sync_once: FAILED ({e})"
            ),
        }
    }

    pub async fn logout(&self) -> anyhow::Result<()> {
        self.stop_sync();
        self.client
            .matrix_auth()
            .logout()
            .await
            .context("logout")?;
        Ok(())
    }
}

async fn direct_room_display_name(room: &Room, own_user: &UserId) -> String {
    if let Ok(members) = room.members(RoomMemberships::ACTIVE).await {
        for m in members {
            if m.user_id() != own_user {
                if let Some(name) = m.display_name() {
                    return name.to_owned();
                }
                return m.user_id().to_string();
            }
        }
    }
    room.name()
        .map(|s| s.to_owned())
        .unwrap_or_else(|| room.room_id().to_string())
}
