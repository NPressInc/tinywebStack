//! Chat UX helpers (reactions, replies, previews, typing, receipts).

use std::collections::HashMap;

use anyhow::{anyhow, Context as _};
use matrix_sdk::{
    deserialized_responses::{TimelineEvent, TimelineEventKind},
    room::{reply::{EnforceThread, Reply}, Room},
    ruma::{
        api::client::{
            authenticated_media::get_media_preview::v1 as auth_preview,
            media::get_media_preview::v3 as legacy_preview,
            receipt::create_receipt,
        },
        events::{
            receipt::{Receipt, ReceiptThread, ReceiptType},
            reaction::ReactionEventContent,
            relation::Annotation,
            room::message::{
                AddMentions, Relation, RoomMessageEventContent, RoomMessageEventContentWithoutRelation,
            },
            AnySyncMessageLikeEvent, AnySyncTimelineEvent, SyncMessageLikeEvent,
        },
        EventId, OwnedEventId, OwnedUserId, UserId,
    },
    Client,
};
use serde_json::Value;

use super::{
    empty_media_fields, media_fields_from_msgtype, member_display_name, timeline_body_from_msgtype,
    timeline_ts_ms, MessageReaction, ReplyPreview, TimelineMessage, UrlPreview, UserReadReceipt,
};

fn snippet(body: &str, max: usize) -> String {
    let t = body.trim();
    if t.len() <= max {
        t.to_owned()
    } else {
        format!("{}…", t.chars().take(max).collect::<String>())
    }
}

fn parse_reaction_event(
    event: &TimelineEvent,
    own_user_id: &UserId,
) -> Option<(String, MessageReaction)> {
    if matches!(event.kind, TimelineEventKind::UnableToDecrypt { .. }) {
        return None;
    }
    let Ok(parsed) = event.raw().deserialize() else {
        return None;
    };
    match parsed {
        AnySyncTimelineEvent::MessageLike(like) => match like {
            AnySyncMessageLikeEvent::Reaction(msg) => {
                let (sender, event_id, content) = match msg {
                    SyncMessageLikeEvent::Original(o) => {
                        (o.sender.clone(), o.event_id.to_string(), o.content.clone())
                    }
                    SyncMessageLikeEvent::Redacted(_) => return None,
                };
                let relates = content.relates_to;
                let target = relates.event_id.to_string();
                let reaction = MessageReaction {
                    emoji: relates.key,
                    user_id: sender.to_string(),
                    reaction_event_id: event_id,
                };
                let _ = own_user_id;
                Some((target, reaction))
            }
            _ => None,
        },
        _ => None,
    }
}

fn in_reply_to_from_content(content: &RoomMessageEventContent) -> Option<OwnedEventId> {
    content.relates_to.as_ref().and_then(|rel| match rel {
        Relation::Reply(reply) => Some(reply.in_reply_to.event_id.clone()),
        _ => None,
    })
}

pub(super) fn build_timeline_messages(
    events: &[TimelineEvent],
    own_user_id: &UserId,
    room: &Room,
) -> Vec<TimelineMessage> {
    let mut reactions: HashMap<String, Vec<MessageReaction>> = HashMap::new();
    let mut bodies: HashMap<String, (String, String, Option<String>)> = HashMap::new();

    for ev in events {
        if let Some((target, reaction)) = parse_reaction_event(ev, own_user_id) {
            reactions.entry(target).or_default().push(reaction);
            continue;
        }
        if let Some(tm) = parse_timeline_message_with_maps(ev, own_user_id, &mut bodies) {
            bodies.insert(
                tm.event_id.clone(),
                (tm.sender.clone(), tm.body.clone(), tm.sender_display_name.clone()),
            );
        }
    }

    let mut messages: Vec<TimelineMessage> = events
        .iter()
        .filter_map(|ev| parse_timeline_message_with_maps(ev, own_user_id, &mut bodies))
        .collect();
    messages.reverse();

    for m in &mut messages {
        if let Some(list) = reactions.remove(&m.event_id) {
            m.reactions = list;
        }
    }
    let _ = room;
    messages
}

fn parse_timeline_message_with_maps(
    event: &TimelineEvent,
    own_user_id: &UserId,
    bodies: &mut HashMap<String, (String, String, Option<String>)>,
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
        let (msgtype, filename, mime_type, width, height, duration_ms) = empty_media_fields();
        return Some(TimelineMessage {
            event_id,
            sender,
            sender_display_name: None,
            body: "Unable to decrypt — sent before this device joined, or restore your recovery key"
                .to_owned(),
            ts_ms,
            is_own,
            utd: true,
            msgtype,
            filename,
            mime_type,
            width,
            height,
            duration_ms,
            reactions: vec![],
            in_reply_to: None,
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
                let body = timeline_body_from_msgtype(&content.msgtype)?;
                let (msgtype, filename, mime_type, width, height, duration_ms) =
                    if let Some((mt, _, fname, mime, w, h, dur)) =
                        media_fields_from_msgtype(&content.msgtype)
                    {
                        (Some(mt), fname, mime, w, h, dur)
                    } else {
                        empty_media_fields()
                    };
                let in_reply_to = in_reply_to_from_content(&content).map(|reply_id| {
                    let key = reply_id.to_string();
                    if let Some((s, b, d)) = bodies.get(&key) {
                        ReplyPreview {
                            event_id: key,
                            sender: s.clone(),
                            sender_display_name: d.clone(),
                            body: snippet(b, 120),
                        }
                    } else {
                        ReplyPreview {
                            event_id: key,
                            sender: String::new(),
                            sender_display_name: None,
                            body: "…".to_owned(),
                        }
                    }
                });
                Some(TimelineMessage {
                    event_id,
                    sender: sender.to_string(),
                    sender_display_name: None,
                    body,
                    ts_ms,
                    is_own: sender == *own_user_id,
                    utd: false,
                    msgtype,
                    filename,
                    mime_type,
                    width,
                    height,
                    duration_ms,
                    reactions: vec![],
                    in_reply_to,
                })
            }
            _ => None,
        },
        _ => None,
    }
}

pub(super) async fn enrich_timeline_display_names(
    room: &Room,
    messages: Vec<TimelineMessage>,
) -> Vec<TimelineMessage> {
    let mut out = Vec::with_capacity(messages.len());
    for m in messages {
        let sender_id = UserId::parse(&m.sender).ok();
        let display = if let Some(uid) = sender_id.as_ref() {
            member_display_name(room, uid).await
        } else {
            None
        };
        let in_reply_to = if let Some(mut reply) = m.in_reply_to {
            if reply.sender.is_empty() {
                if let Ok(id) = EventId::parse(&reply.event_id) {
                    if let Ok(ev) = room.load_or_fetch_event(&id, None).await {
                        if let Ok(parsed) = ev.raw().deserialize() {
                            if let AnySyncTimelineEvent::MessageLike(like) = parsed {
                                if let AnySyncMessageLikeEvent::RoomMessage(msg) = like {
                                    if let SyncMessageLikeEvent::Original(o) = msg {
                                        reply.sender = o.sender.to_string();
                                        reply.body = timeline_body_from_msgtype(&o.content.msgtype)
                                            .map(|b| snippet(b.as_str(), 120))
                                            .unwrap_or_else(|| "…".to_owned());
                                        reply.sender_display_name =
                                            member_display_name(room, &o.sender).await;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Some(reply)
        } else {
            None
        };
        out.push(TimelineMessage {
            sender_display_name: display,
            in_reply_to,
            ..m
        });
    }
    out
}

pub(super) async fn send_reaction(
    room: &Room,
    target_event_id: &str,
    emoji: &str,
) -> anyhow::Result<String> {
    let eid = EventId::parse(target_event_id).context("parse event_id")?;
    let content =
        ReactionEventContent::new(Annotation::new(eid.to_owned(), emoji.to_owned()));
    let resp = room.send(content).await.context("send reaction")?;
    Ok(resp.response.event_id.to_string())
}

pub(super) async fn redact_event(
    room: &Room,
    event_id: &str,
    reason: Option<String>,
) -> anyhow::Result<()> {
    let eid = EventId::parse(event_id).context("parse event_id")?;
    room.redact(&eid, reason.as_deref(), None)
        .await
        .context("redact")?;
    Ok(())
}

pub(super) async fn send_text_reply(
    room: &Room,
    body: String,
    reply_to_event_id: String,
) -> anyhow::Result<String> {
    let eid = EventId::parse(&reply_to_event_id).context("parse reply event_id")?;
    let content = RoomMessageEventContentWithoutRelation::text_plain(body);
    let reply = Reply {
        event_id: eid.to_owned(),
        enforce_thread: EnforceThread::Unthreaded,
        add_mentions: AddMentions::No,
    };
    let event_content = room
        .make_reply_event(content, reply)
        .await
        .map_err(|e| anyhow!("make_reply_event: {e}"))?;
    let result = room.send(event_content).await.context("send reply")?;
    Ok(result.response.event_id.to_string())
}

pub(super) async fn send_typing_notice(room: &Room, typing: bool) -> anyhow::Result<()> {
    room.typing_notice(typing).await.context("typing_notice")?;
    Ok(())
}

pub(super) async fn send_read_receipt(room: &Room, event_id: &str) -> anyhow::Result<()> {
    let eid = EventId::parse(event_id).context("parse event_id")?;
    room.send_single_receipt(
        create_receipt::v3::ReceiptType::Read,
        ReceiptThread::Unthreaded,
        eid.to_owned(),
    )
    .await
    .context("send read receipt")?;
    Ok(())
}

pub(super) async fn read_receipts_for_event(
    room: &Room,
    event_id: &str,
) -> anyhow::Result<Vec<UserReadReceipt>> {
    let eid = EventId::parse(event_id).context("parse event_id")?;
    let receipts = room
        .load_event_receipts(ReceiptType::Read, &ReceiptThread::Unthreaded, &eid)
        .await
        .context("load_event_receipts")?;
    Ok(receipts
        .into_iter()
        .map(|(user, receipt)| UserReadReceipt {
            user_id: user.to_string(),
            ts_ms: receipt_ts_ms(&receipt),
        })
        .collect())
}

fn receipt_ts_ms(receipt: &Receipt) -> Option<i64> {
    receipt.ts.map(|t| t.get().into())
}

pub(super) async fn fetch_url_preview(client: &Client, url: &str) -> anyhow::Result<UrlPreview> {
    let auth_req = auth_preview::Request::new(url.to_owned());
    let data = match client.send(auth_req).await {
        Ok(resp) => resp.data,
        Err(_) => {
            let legacy_req = legacy_preview::Request::new(url.to_owned());
            client
                .send(legacy_req)
                .await
                .context("legacy preview_url")?
                .data
        }
    };
    parse_preview_json(url, data)
}

fn parse_preview_json(
    url: &str,
    data: Option<Box<serde_json::value::RawValue>>,
) -> anyhow::Result<UrlPreview> {
    let Some(raw) = data else {
        return Ok(UrlPreview {
            url: url.to_owned(),
            title: None,
            description: None,
            image_mxc: None,
            site_name: None,
        });
    };
    let v: Value = serde_json::from_str(raw.get()).context("parse preview json")?;
    let title = v.get("og:title").and_then(|x| x.as_str()).map(|s| s.to_owned());
    let description = v
        .get("og:description")
        .and_then(|x| x.as_str())
        .map(|s| s.to_owned());
    let image_mxc = v
        .get("og:image")
        .and_then(|x| x.as_str())
        .map(|s| s.to_owned());
    let site_name = v
        .get("og:site_name")
        .and_then(|x| x.as_str())
        .map(|s| s.to_owned());
    Ok(UrlPreview {
        url: url.to_owned(),
        title,
        description,
        image_mxc,
        site_name,
    })
}

fn apply_reaction_to_list(
    reactions: &mut Vec<MessageReaction>,
    own_user_id: &str,
    emoji: &str,
    reaction_event_id: &str,
    remove: bool,
) {
    reactions.retain(|r| r.user_id != own_user_id);
    if !remove {
        reactions.push(MessageReaction {
            emoji: emoji.to_owned(),
            user_id: own_user_id.to_owned(),
            reaction_event_id: reaction_event_id.to_owned(),
        });
    }
}

fn body_snippet_for_reply(body: &str) -> String {
    snippet(body, 120)
}

pub(super) async fn reply_preview_from_message_content(
    content: &RoomMessageEventContent,
    room: &Room,
) -> Option<ReplyPreview> {
    let reply_id = in_reply_to_from_content(content)?;
    let key = reply_id.to_string();
    if let Ok(ev) = room.load_or_fetch_event(&reply_id, None).await {
        if let Ok(parsed) = ev.raw().deserialize() {
            if let AnySyncTimelineEvent::MessageLike(like) = parsed {
                if let AnySyncMessageLikeEvent::RoomMessage(msg) = like {
                    if let SyncMessageLikeEvent::Original(o) = msg {
                        let body = timeline_body_from_msgtype(&o.content.msgtype)
                            .map(|b| snippet(b.as_str(), 120))
                            .unwrap_or_else(|| "…".to_owned());
                        let display = member_display_name(room, &o.sender).await;
                        return Some(ReplyPreview {
                            event_id: key,
                            sender: o.sender.to_string(),
                            sender_display_name: display,
                            body,
                        });
                    }
                }
            }
        }
    }
    Some(ReplyPreview {
        event_id: key,
        sender: String::new(),
        sender_display_name: None,
        body: "…".to_owned(),
    })
}
