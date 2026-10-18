//! JSON API. Everything except `/healthz` requires `Authorization: Bearer <API_KEY>`.
//! Rate limiting runs before auth so key guessing is throttled too.

use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    num::NonZeroU32,
    sync::Arc,
    time::Duration,
};

use alloy::primitives::keccak256;
use axum::{
    Json, Router,
    extract::{ConnectInfo, Query, Request, State},
    http::{HeaderMap, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
};
use governor::{DefaultKeyedRateLimiter, Quota, RateLimiter};
use serde::Deserialize;
use serde_json::json;
use subtle::ConstantTimeEq;
use tower_http::{limit::RequestBodyLimitLayer, timeout::TimeoutLayer};
use tracing::error;

use crate::{db::Db, keeper::SharedStatus, rpc::RpcPool, tx::now_secs};

const MAX_LIMIT: i64 = 500;

#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub rpc: Arc<RpcPool>,
    pub status: SharedStatus,
    /// keccak256 of the API key: compared in constant time against the hash of the presented token.
    pub key_hash: [u8; 32],
    pub limiter: Arc<DefaultKeyedRateLimiter<IpAddr>>,
}

impl AppState {
    pub fn new(db: Db, rpc: Arc<RpcPool>, status: SharedStatus, api_key: &[u8], per_sec: u32) -> Self {
        let per_sec = NonZeroU32::new(per_sec.max(1)).expect("non-zero");
        let quota = Quota::per_second(per_sec).allow_burst(per_sec.saturating_mul(NonZeroU32::new(2).expect("2")));
        Self {
            db,
            rpc,
            status,
            key_hash: keccak256(api_key).0,
            limiter: Arc::new(RateLimiter::keyed(quota)),
        }
    }
}

pub fn router(state: AppState) -> Router {
    let protected = Router::new()
        .route("/status", get(status))
        .route("/strategy", get(strategy))
        .route("/rpc", get(rpc_health))
        .route("/rewards", get(rewards))
        .route("/rebalances", get(rebalances))
        .route("/deposits", get(deposits))
        .route("/withdrawals", get(withdrawals))
        .route("/swaps", get(swaps))
        .route("/actions", get(actions))
        .route("/snapshots", get(snapshots))
        .route("/price-history", get(price_history))
        .route_layer(middleware::from_fn_with_state(state.clone(), auth));

    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .merge(protected)
        .layer(middleware::from_fn_with_state(state.clone(), rate_limit))
        .layer(RequestBodyLimitLayer::new(1024 * 1024))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            Duration::from_secs(10),
        ))
        .with_state(state)
}

pub async fn serve(state: AppState, bind: SocketAddr) -> anyhow::Result<()> {
    let listener = tokio::net::TcpListener::bind(bind).await?;
    axum::serve(
        listener,
        router(state).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}

async fn rate_limit(State(s): State<AppState>, req: Request, next: Next) -> Response {
    let ip = req
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|c| c.0.ip())
        .unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
    if s.limiter.check_key(&ip).is_err() {
        return (StatusCode::TOO_MANY_REQUESTS, Json(json!({"error": "rate limited"}))).into_response();
    }
    next.run(req).await
}

fn authorized(headers: &HeaderMap, key_hash: &[u8; 32]) -> bool {
    let Some(token) = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
    else {
        return false;
    };
    // Hash first so the comparison is fixed-length and constant-time.
    keccak256(token.as_bytes()).0.ct_eq(key_hash).into()
}

async fn auth(State(s): State<AppState>, req: Request, next: Next) -> Response {
    if !authorized(req.headers(), &s.key_hash) {
        return (StatusCode::UNAUTHORIZED, Json(json!({"error": "unauthorized"}))).into_response();
    }
    next.run(req).await
}

fn internal(e: anyhow::Error) -> Response {
    // Never echo internals to the client.
    error!(error = %e, "api error");
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({"error": "internal error"})),
    )
        .into_response()
}

#[derive(Deserialize)]
struct Page {
    limit: Option<i64>,
    offset: Option<i64>,
}

impl Page {
    fn args(&self) -> Vec<i64> {
        vec![
            self.limit.unwrap_or(100).clamp(1, MAX_LIMIT),
            self.offset.unwrap_or(0).max(0),
        ]
    }
}

async fn list(s: &AppState, sql: &'static str, p: &Page) -> Response {
    match s.db.query_json(sql, p.args()).await {
        Ok(rows) => Json(json!({ "items": rows })).into_response(),
        Err(e) => internal(e),
    }
}

async fn status(State(s): State<AppState>) -> Response {
    let st = s.status.read().unwrap_or_else(|e| e.into_inner()).clone();
    Json(st).into_response()
}

async fn strategy(State(s): State<AppState>) -> Response {
    let st = s.status.read().unwrap_or_else(|e| e.into_inner()).clone();
    Json(json!({
        "sigma_daily": st.sigma_daily,
        "chosen_half_width": st.chosen_half_width,
        "min_half_width": st.min_half_width,
        "max_half_width": st.max_half_width,
        "trigger_distance_bps": st.trigger_distance_bps,
        "recenter_threshold_bps": st.recenter_threshold_bps,
        "decision": st.decision,
    }))
    .into_response()
}

async fn rpc_health(State(s): State<AppState>) -> Response {
    Json(json!({ "best_head": s.rpc.best_head(), "endpoints": s.rpc.statuses() })).into_response()
}

#[derive(Deserialize)]
struct Period {
    days: Option<i64>,
}

async fn rewards(State(s): State<AppState>, Query(q): Query<Period>) -> Response {
    let days = q.days.unwrap_or(30).clamp(1, 3650);
    let since = now_secs() as i64 - days * 86_400;
    let daily =
        s.db.query_json(
            "SELECT (ts / 86400) * 86400 AS day, sum(accrued_fees_value1) AS fees_value1,
                    avg(tvl_value1) AS avg_tvl_value1, min(in_range) AS always_in_range
             FROM snapshots WHERE ts >= ? GROUP BY day ORDER BY day",
            vec![since],
        )
        .await;
    let totals = s
        .db
        .query_json(
            "SELECT coalesce(sum(accrued_fees_value1), 0) AS fees_value1, coalesce(avg(tvl_value1), 0) AS avg_tvl_value1,
                    coalesce(avg(CASE WHEN in_range THEN 1.0 ELSE 0.0 END), 0) AS time_in_range,
                    coalesce(min(ts), 0) AS first_ts, coalesce(max(ts), 0) AS last_ts
             FROM snapshots WHERE ts >= ?",
            vec![since],
        )
        .await;
    let gas =
        s.db.query_json(
            "SELECT count(*) AS txs, coalesce(sum(CAST(gas_cost_wei AS DOUBLE)), 0) / 1e18 AS gas_eth
             FROM actions WHERE ts >= ? AND gas_cost_wei IS NOT NULL",
            vec![since],
        )
        .await;
    let rebal =
        s.db.query_json(
            "SELECT count(*) AS rebalances, coalesce(sum(fees_value1), 0) AS collected_fees_value1
             FROM rebalances WHERE ts >= ?",
            vec![since],
        )
        .await;
    match (daily, totals, gas, rebal) {
        (Ok(mut daily), Ok(t), Ok(g), Ok(r)) => {
            // SQLite aggregates booleans as 0/1.
            for d in &mut daily {
                d["always_in_range"] = json!(d["always_in_range"].as_i64() == Some(1));
            }
            let t = &t[0];
            let fees = t["fees_value1"].as_f64().unwrap_or(0.0);
            let tvl = t["avg_tvl_value1"].as_f64().unwrap_or(0.0);
            let span_days = (t["last_ts"].as_f64().unwrap_or(0.0) - t["first_ts"].as_f64().unwrap_or(0.0)) / 86_400.0;
            let apr = if tvl > 0.0 && span_days > 0.0 {
                fees / tvl * 365.0 / span_days
            } else {
                0.0
            };
            Json(json!({
                "period_days": days,
                "units": "token1 base units (XAUT: 1e6 = 1 XAUT)",
                "fees_value1": fees,
                "avg_tvl_value1": tvl,
                "fee_apr": apr,
                "time_in_range": t["time_in_range"],
                "gas": g[0],
                "rebalances": r[0],
                "daily": daily,
            }))
            .into_response()
        }
        (Err(e), ..) | (_, Err(e), ..) | (_, _, Err(e), _) | (.., Err(e)) => internal(e),
    }
}

async fn rebalances(State(s): State<AppState>, Query(p): Query<Page>) -> Response {
    list(
        &s,
        "SELECT * FROM rebalances ORDER BY block DESC, log_index DESC LIMIT ? OFFSET ?",
        &p,
    )
    .await
}

async fn deposits(State(s): State<AppState>, Query(p): Query<Page>) -> Response {
    list(
        &s,
        "SELECT * FROM deposits ORDER BY block DESC, log_index DESC LIMIT ? OFFSET ?",
        &p,
    )
    .await
}

async fn withdrawals(State(s): State<AppState>, Query(p): Query<Page>) -> Response {
    list(
        &s,
        "SELECT * FROM withdrawals ORDER BY block DESC, log_index DESC LIMIT ? OFFSET ?",
        &p,
    )
    .await
}

async fn swaps(State(s): State<AppState>, Query(p): Query<Page>) -> Response {
    list(
        &s,
        "SELECT * FROM swaps ORDER BY block DESC, log_index DESC LIMIT ? OFFSET ?",
        &p,
    )
    .await
}

async fn actions(State(s): State<AppState>, Query(p): Query<Page>) -> Response {
    list(&s, "SELECT * FROM actions ORDER BY id DESC LIMIT ? OFFSET ?", &p).await
}

async fn snapshots(State(s): State<AppState>, Query(p): Query<Page>) -> Response {
    list(&s, "SELECT * FROM snapshots ORDER BY ts DESC LIMIT ? OFFSET ?", &p).await
}

#[derive(Deserialize)]
struct Range {
    from: Option<i64>,
    to: Option<i64>,
}

async fn price_history(State(s): State<AppState>, Query(r): Query<Range>) -> Response {
    let to = r.to.unwrap_or(now_secs() as i64);
    let from = r.from.unwrap_or(to - 7 * 86_400);
    match s
        .db
        .query_json(
            "SELECT ts, block, tick FROM price_samples WHERE ts >= ? AND ts <= ? ORDER BY ts LIMIT 5000",
            vec![from, to],
        )
        .await
    {
        Ok(mut rows) => {
            // Bundled SQLite has no math functions; price = 1.0001^tick is computed here.
            for r in &mut rows {
                let tick = r["tick"].as_i64().unwrap_or(0) as i32;
                r["price"] = json!(1.0001f64.powi(tick));
            }
            Json(json!({ "items": rows })).into_response()
        }
        Err(e) => internal(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keeper::Status;
    use axum::body::Body;
    use serde_json::Value;
    use std::sync::RwLock;
    use tower::ServiceExt;

    const KEY: &str = "0123456789abcdef0123456789abcdef";

    async fn app(per_sec: u32) -> Router {
        // A pool pointing at nothing reachable is fine: these routes don't hit it except /rpc.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let mock = Router::new().route(
            "/",
            axum::routing::post(|Json(v): Json<Value>| async move {
                Json(json!({"jsonrpc":"2.0","id":v["id"],"result":"0x1"}))
            }),
        );
        tokio::spawn(async move { axum::serve(listener, mock).await.unwrap() });
        let url = reqwest::Url::parse(&format!("http://{addr}/")).unwrap();
        let rpc = Arc::new(RpcPool::connect(&[url], 1, Duration::from_secs(2), 3).await.unwrap());
        let status: SharedStatus = Arc::new(RwLock::new(Status::default()));
        router(AppState::new(
            Db::open_in_memory().unwrap(),
            rpc,
            status,
            KEY.as_bytes(),
            per_sec,
        ))
    }

    fn req(path: &str, token: Option<&str>) -> Request<Body> {
        let mut b = axum::http::Request::builder().uri(path);
        if let Some(t) = token {
            b = b.header(header::AUTHORIZATION, format!("Bearer {t}"));
        }
        b.body(Body::empty()).unwrap()
    }

    #[tokio::test]
    async fn healthz_is_public() {
        let r = app(100).await.oneshot(req("/healthz", None)).await.unwrap();
        assert_eq!(r.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn protected_routes_require_key() {
        for path in [
            "/status",
            "/strategy",
            "/rpc",
            "/rewards",
            "/rebalances",
            "/actions",
            "/price-history",
        ] {
            let a = app(100).await;
            assert_eq!(
                a.clone().oneshot(req(path, None)).await.unwrap().status(),
                StatusCode::UNAUTHORIZED,
                "{path}"
            );
            assert_eq!(
                a.clone()
                    .oneshot(req(path, Some("wrong-key-wrong-key-wrong-key-xx")))
                    .await
                    .unwrap()
                    .status(),
                StatusCode::UNAUTHORIZED,
                "{path}"
            );
            assert_eq!(
                a.oneshot(req(path, Some(KEY))).await.unwrap().status(),
                StatusCode::OK,
                "{path}"
            );
        }
    }

    #[tokio::test]
    async fn non_bearer_scheme_rejected() {
        let mut r = req("/status", None);
        r.headers_mut()
            .insert(header::AUTHORIZATION, format!("Basic {KEY}").parse().unwrap());
        assert_eq!(
            app(100).await.oneshot(r).await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
    }

    #[tokio::test]
    async fn rate_limited() {
        let a = app(1).await; // burst 2
        let mut codes = Vec::new();
        for _ in 0..5 {
            codes.push(a.clone().oneshot(req("/healthz", None)).await.unwrap().status());
        }
        assert!(codes.contains(&StatusCode::TOO_MANY_REQUESTS));
    }

    #[tokio::test]
    async fn pagination_is_clamped() {
        let p = Page {
            limit: Some(1_000_000),
            offset: Some(-5),
        };
        assert_eq!(p.args(), vec![MAX_LIMIT, 0]);
    }
}
