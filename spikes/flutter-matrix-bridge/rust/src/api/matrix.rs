use std::{
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Duration,
};

use anyhow::{Context as _, anyhow};
use crate::frb_generated::StreamSink;
use matrix_sdk::{
    Client,
    config::SyncSettings,
    ruma::{
        api::client::room::create_room,
        assign,
        events::room::{
            encryption::RoomEncryptionEventContent,
            message::{MessageType, RoomMessageEventContent, SyncRoomMessageEvent},
            member::{MembershipState, StrippedRoomMemberEvent, SyncRoomMemberEvent},
        },
        events::InitialStateEvent,
        serde::Raw,
        OwnedUserId, RoomId, UserId,
    },
    reqwest::Certificate,
    sliding_sync::{SlidingSyncList, SlidingSyncMode, Version as SlidingSyncVersion},
    Room, RoomState,
};
use matrix_sdk::deserialized_responses::EncryptionInfo;
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;
use tracing::{info, warn};
use url::Url;

static TOKIO_RT: OnceLock<Runtime> = OnceLock::new();

fn runtime() -> &'static Runtime {
    TOKIO_RT.get_or_init(|| {
        Runtime::new().expect("failed to build tokio runtime")
    })
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
}

#[derive(Clone, Debug)]
pub struct IncomingMessage {
    pub room_id: String,
    pub sender: String,
    pub body: String,
    pub event_id: String,
    pub was_encrypted: bool,
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
        let mut out = Vec::new();
        for room in self.client.joined_rooms() {
            let room_id = room.room_id().to_string();
            let name = room
                .name()
                .map(|s| s.to_owned())
                .unwrap_or_else(|| room_id.clone());
            let is_encrypted = room
                .latest_encryption_state()
                .await
                .map(|s| s.is_encrypted())
                .unwrap_or(false);
            let joined_members = room.active_members_count().min(u32::MAX as u64) as u32;
            out.push(RoomSummary {
                room_id,
                name,
                is_encrypted,
                joined_members,
            });
        }
        Ok(out)
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
            .context("send message")?;
        Ok(result.response.event_id.to_string())
    }

    pub fn start_sync(&self, sink: StreamSink<IncomingMessage>) {
        self.stop_sync();

        let client = self.client.clone();
        let stop = self.sync_stop.clone();
        stop.store(false, Ordering::SeqCst);

        let mut handles = Vec::new();

        handles.push(client.add_event_handler(
            move |ev: SyncRoomMessageEvent,
                  room: Room,
                  encryption_info: Option<EncryptionInfo>| {
                let sink = sink.clone();
                async move {
                    let Some(original) = ev.as_original() else {
                        return;
                    };
                    if let MessageType::Text(text) = &original.content.msgtype {
                        let msg = IncomingMessage {
                            room_id: room.room_id().to_string(),
                            sender: original.sender.to_string(),
                            body: text.body.clone(),
                            event_id: original.event_id.to_string(),
                            was_encrypted: encryption_info.is_some(),
                        };
                        let _ = sink.add(msg);
                    }
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

        let handle = runtime().spawn(async move {
            let settings = SyncSettings::default().timeout(Duration::from_secs(30));
            while !stop.load(Ordering::SeqCst) {
                match client.sync_once(settings.clone()).await {
                    Ok(_) => {}
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
