//! Track details shared by Connect notifications and the local Browse endpoint.
use std::{collections::VecDeque, sync::Mutex, time::{Duration, Instant}};
use librespot_core::{Session, SpotifyUri};
use librespot_metadata::audio::{AudioItem, UniqueFields};
use serde_json::{json, Value};

/// Bound memory independently of the size of the user's library.
const CAPACITY: usize = 128;
/// Refresh titles and artwork after one hour, using monotonic time.
const TTL: Duration = Duration::from_secs(3600);

/// Playback events seed this cache; endpoint misses use the playback session.
#[derive(Default)]
pub(crate) struct MetadataStore {
    /// Insertion order permits bounded eviction; each entry records its fetch time.
    entries: Mutex<VecDeque<(String, Instant, Value)>>,
    /// Serialize misses so concurrent requests for one track share the result.
    lookup: tokio::sync::Mutex<()>,
}

impl MetadataStore {
    /// Only return fresh metadata; never hold this synchronous lock across an await.
    fn cached(&self, uri: &str) -> Option<Value> {
        self.entries.lock().unwrap_or_else(|e| e.into_inner()).iter()
            .find(|(key, at, _)| key == uri && at.elapsed() < TTL)
            .map(|(_, _, value)| value.clone())
    }

    /// Replace an existing entry and evict oldest entries at the fixed capacity.
    fn insert(&self, uri: String, value: Value) {
        let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
        entries.retain(|(key, _, _)| key != &uri);
        entries.push_back((uri, Instant::now(), value));
        while entries.len() > CAPACITY { entries.pop_front(); }
    }

    /// Store details already loaded by the player without making another request.
    pub(crate) fn remember(&self, item: &AudioItem) {
        if let Some(value) = track_metadata(item) {
            self.insert(item.track_id.to_uri(), value);
        }
    }

    /// Fetch music metadata for an ID validated by the HTTP handler without loading audio.
    /// The timeout includes queueing behind another miss; failures remain uncached.
    pub(crate) async fn get(&self, session: &Session, id: &str) -> Option<Value> {
        let uri = format!("spotify:track:{id}");
        if let Some(value) = self.cached(&uri) { return Some(value); }
        tokio::time::timeout(Duration::from_secs(8), async {
            let _guard = self.lookup.lock().await;
            if let Some(value) = self.cached(&uri) { return Some(value); }
            let item = AudioItem::get_file(session, SpotifyUri::from_uri(&uri).ok()?).await.ok()?;
            let value = track_metadata(&item)?;
            // Reject unexpected identities so callers never cache another track's details.
            if value["uri"].as_str() != Some(uri.as_str()) { return None; }
            self.insert(uri, value.clone());
            Some(value)
        }).await.ok().flatten()
    }
}

/// Convert already-loaded music metadata to the subset of the Web API track
/// shape used by LMS. No network requests are made; unsupported item types
/// retain the existing fallback path.
pub(crate) fn track_metadata(item: &AudioItem) -> Option<serde_json::Value> {
    let UniqueFields::Track { artists, album, album_artists, .. } = &item.unique_fields else {
        return None;
    };
    let mut names: Vec<&str> = Vec::new();
    let mut artist_details = Vec::new();
    for artist in artists.iter() {
        if !names.contains(&artist.name.as_str()) {
            names.push(&artist.name);
            artist_details.push(json!({"name": artist.name, "id": artist.id.to_id()}));
        }
    }
    if names.is_empty() {
        artist_details.extend(album_artists.iter().map(|name| json!({"name": name})));
    }
    Some(json!({
        "uri": item.track_id.to_uri(),
        "name": item.name,
        "duration_ms": item.duration_ms,
        "artists": artist_details,
        "album": {
            "name": album,
            "images": item.covers.iter().map(|cover| json!({
                "url": cover.url, "width": cover.width, "height": cover.height,
            })).collect::<Vec<_>>(),
        },
    }))
}


/// Cache behavior can be checked without a Spotify session.
#[cfg(test)]
mod tests {
    use super::*;

    /// Replacement, expiry and capacity must not expose stale or unrelated tracks.
    #[test]
    fn bounded_fresh_cache() {
        let store = MetadataStore::default();
        store.insert("track".into(), json!({"name":"old"}));
        store.insert("track".into(), json!({"name":"new"}));
        assert_eq!(store.cached("track").unwrap()["name"], "new");
        assert_eq!(store.entries.lock().unwrap().len(), 1);
        store.entries.lock().unwrap()[0].1 = Instant::now() - TTL;
        assert!(store.cached("track").is_none());
        for i in 0..CAPACITY { store.insert(i.to_string(), json!({"id":i})); }
        assert_eq!(store.entries.lock().unwrap().len(), CAPACITY);
        assert!(!store.entries.lock().unwrap().iter().any(|(key, _, _)| key == "track"));
        assert_eq!(store.cached("127").unwrap()["id"], 127);
    }
}
