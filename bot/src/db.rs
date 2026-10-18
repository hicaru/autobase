//! DuckDB storage. One connection behind a mutex; every call runs on the blocking pool.
//! SQL is always static text with bound parameters — never string-interpolated input.

use std::{
    path::Path,
    sync::{Arc, Mutex},
};

use duckdb::{Connection, ToSql, params, types::ValueRef};
use serde::Serialize;
use serde_json::{Map, Value, json};

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS kv (k VARCHAR PRIMARY KEY, v VARCHAR NOT NULL);

CREATE TABLE IF NOT EXISTS price_samples (ts BIGINT PRIMARY KEY, block BIGINT NOT NULL, tick INTEGER NOT NULL);

CREATE TABLE IF NOT EXISTS snapshots (
    ts BIGINT PRIMARY KEY, block BIGINT NOT NULL, tick INTEGER NOT NULL,
    tick_lower INTEGER NOT NULL, tick_upper INTEGER NOT NULL, in_range BOOLEAN NOT NULL,
    liquidity VARCHAR NOT NULL, total0 VARCHAR NOT NULL, total1 VARCHAR NOT NULL, tvl_value1 DOUBLE NOT NULL,
    pending_fees0 VARCHAR NOT NULL, pending_fees1 VARCHAR NOT NULL, pending_fees_value1 DOUBLE NOT NULL,
    fee_growth_inside0 VARCHAR NOT NULL, fee_growth_inside1 VARCHAR NOT NULL,
    accrued_fees0 VARCHAR NOT NULL, accrued_fees1 VARCHAR NOT NULL, accrued_fees_value1 DOUBLE NOT NULL,
    total_supply VARCHAR NOT NULL, share_price DOUBLE NOT NULL, price DOUBLE NOT NULL
);

CREATE TABLE IF NOT EXISTS deposits (block BIGINT, log_index INTEGER, tx_hash VARCHAR, ts BIGINT,
    "user" VARCHAR, amount0 VARCHAR, amount1 VARCHAR, shares VARCHAR, PRIMARY KEY (block, log_index));
CREATE TABLE IF NOT EXISTS withdrawals (block BIGINT, log_index INTEGER, tx_hash VARCHAR, ts BIGINT,
    "user" VARCHAR, shares VARCHAR, amount0 VARCHAR, amount1 VARCHAR, PRIMARY KEY (block, log_index));
CREATE TABLE IF NOT EXISTS rebalances (block BIGINT, log_index INTEGER, tx_hash VARCHAR, ts BIGINT,
    old_lower INTEGER, old_upper INTEGER, new_lower INTEGER, new_upper INTEGER, half_width INTEGER,
    liquidity_added VARCHAR, fees0 VARCHAR, fees1 VARCHAR, fees_value1 DOUBLE, PRIMARY KEY (block, log_index));
CREATE TABLE IF NOT EXISTS swaps (block BIGINT, log_index INTEGER, tx_hash VARCHAR, ts BIGINT,
    zero_for_one BOOLEAN, amount_in VARCHAR, amount_out VARCHAR, PRIMARY KEY (block, log_index));
CREATE TABLE IF NOT EXISTS admin_events (block BIGINT, log_index INTEGER, tx_hash VARCHAR, ts BIGINT,
    kind VARCHAR, detail VARCHAR, PRIMARY KEY (block, log_index));

CREATE SEQUENCE IF NOT EXISTS action_id;
CREATE TABLE IF NOT EXISTS actions (
    id BIGINT PRIMARY KEY DEFAULT nextval('action_id'), ts BIGINT NOT NULL, decision VARCHAR NOT NULL,
    reason VARCHAR, half_width INTEGER, tx_hash VARCHAR, status VARCHAR NOT NULL,
    gas_used BIGINT, gas_cost_wei VARCHAR, error VARCHAR
);

CREATE TABLE IF NOT EXISTS pending_tx (
    id INTEGER PRIMARY KEY, action_id BIGINT NOT NULL, tx_hash VARCHAR NOT NULL, nonce BIGINT NOT NULL,
    raw VARCHAR NOT NULL, sent_block BIGINT NOT NULL, deadline BIGINT NOT NULL
);
"#;

#[derive(Clone)]
pub struct Db(Arc<Mutex<Connection>>);

#[derive(Debug, Clone, Serialize)]
pub struct Snapshot {
    pub ts: i64,
    pub block: u64,
    pub tick: i32,
    pub tick_lower: i32,
    pub tick_upper: i32,
    pub in_range: bool,
    pub liquidity: String,
    pub total0: String,
    pub total1: String,
    pub tvl_value1: f64,
    pub pending_fees0: String,
    pub pending_fees1: String,
    pub pending_fees_value1: f64,
    pub fee_growth_inside0: String,
    pub fee_growth_inside1: String,
    pub accrued_fees0: String,
    pub accrued_fees1: String,
    pub accrued_fees_value1: f64,
    pub total_supply: String,
    pub share_price: f64,
    pub price: f64,
}

#[derive(Debug, Clone)]
pub struct PendingTx {
    pub action_id: i64,
    pub tx_hash: String,
    pub nonce: u64,
    pub raw: String,
    pub sent_block: u64,
    pub deadline: u64,
}

impl Db {
    pub fn open(path: &Path) -> anyhow::Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self(Arc::new(Mutex::new(conn))))
    }

    #[cfg(test)]
    pub fn open_in_memory() -> anyhow::Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self(Arc::new(Mutex::new(conn))))
    }

    /// Runs `f` with the connection on the blocking pool.
    pub async fn run<T, F>(&self, f: F) -> anyhow::Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&Connection) -> duckdb::Result<T> + Send + 'static,
    {
        let db = self.0.clone();
        let out = tokio::task::spawn_blocking(move || {
            let conn = db.lock().unwrap_or_else(|e| e.into_inner());
            f(&conn)
        })
        .await??;
        Ok(out)
    }

    pub async fn kv_get(&self, k: &'static str) -> anyhow::Result<Option<String>> {
        self.run(move |c| {
            let mut s = c.prepare("SELECT v FROM kv WHERE k = ?")?;
            let mut rows = s.query(params![k])?;
            Ok(match rows.next()? {
                Some(r) => Some(r.get::<_, String>(0)?),
                None => None,
            })
        })
        .await
    }

    pub async fn kv_set(&self, k: &'static str, v: String) -> anyhow::Result<()> {
        self.run(move |c| {
            c.execute("INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)", params![k, v])?;
            Ok(())
        })
        .await
    }

    pub async fn insert_price_sample(&self, ts: i64, block: u64, tick: i32) -> anyhow::Result<()> {
        self.run(move |c| {
            c.execute(
                "INSERT OR IGNORE INTO price_samples (ts, block, tick) VALUES (?, ?, ?)",
                params![ts, block as i64, tick],
            )?;
            Ok(())
        })
        .await
    }

    pub async fn price_samples_since(&self, since_ts: i64) -> anyhow::Result<Vec<(i64, i32)>> {
        self.run(move |c| {
            let mut s = c.prepare("SELECT ts, tick FROM price_samples WHERE ts >= ? ORDER BY ts")?;
            let rows = s.query_map(params![since_ts], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect()
        })
        .await
    }

    pub async fn insert_snapshot(&self, s: Snapshot) -> anyhow::Result<()> {
        self.run(move |c| {
            c.execute(
                "INSERT OR REPLACE INTO snapshots VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                params![
                    s.ts,
                    s.block as i64,
                    s.tick,
                    s.tick_lower,
                    s.tick_upper,
                    s.in_range,
                    s.liquidity,
                    s.total0,
                    s.total1,
                    s.tvl_value1,
                    s.pending_fees0,
                    s.pending_fees1,
                    s.pending_fees_value1,
                    s.fee_growth_inside0,
                    s.fee_growth_inside1,
                    s.accrued_fees0,
                    s.accrued_fees1,
                    s.accrued_fees_value1,
                    s.total_supply,
                    s.share_price,
                    s.price
                ],
            )?;
            Ok(())
        })
        .await
    }

    /// (tick_lower, tick_upper, liquidity, fee_growth_inside0, fee_growth_inside1) of the latest snapshot.
    pub async fn last_snapshot_growth(&self) -> anyhow::Result<Option<(i32, i32, String, String, String)>> {
        self.run(|c| {
            let mut s = c.prepare(
                "SELECT tick_lower, tick_upper, liquidity, fee_growth_inside0, fee_growth_inside1
                 FROM snapshots ORDER BY ts DESC LIMIT 1",
            )?;
            let mut rows = s.query([])?;
            Ok(match rows.next()? {
                Some(r) => Some((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
                None => None,
            })
        })
        .await
    }

    /// Inserts one event row into `table` (a fixed table name chosen by the indexer, never user input).
    pub async fn insert_event(&self, table: EventTable, values: Vec<Box<dyn ToSql + Send>>) -> anyhow::Result<()> {
        self.run(move |c| {
            let refs: Vec<&dyn ToSql> = values.iter().map(|v| v.as_ref() as &dyn ToSql).collect();
            c.execute(table.insert_sql(), refs.as_slice())?;
            Ok(())
        })
        .await
    }

    pub async fn insert_action(
        &self,
        ts: i64,
        decision: String,
        reason: Option<String>,
        half_width: Option<i32>,
        status: &'static str,
    ) -> anyhow::Result<i64> {
        self.run(move |c| {
            c.query_row(
                "INSERT INTO actions (ts, decision, reason, half_width, status) VALUES (?, ?, ?, ?, ?) RETURNING id",
                params![ts, decision, reason, half_width, status],
                |r| r.get(0),
            )
        })
        .await
    }

    pub async fn update_action(
        &self,
        id: i64,
        status: &'static str,
        tx_hash: Option<String>,
        gas_used: Option<u64>,
        gas_cost_wei: Option<String>,
        error: Option<String>,
    ) -> anyhow::Result<()> {
        self.run(move |c| {
            c.execute(
                "UPDATE actions SET status = ?, tx_hash = COALESCE(?, tx_hash), gas_used = COALESCE(?, gas_used),
                 gas_cost_wei = COALESCE(?, gas_cost_wei), error = COALESCE(?, error) WHERE id = ?",
                params![status, tx_hash, gas_used.map(|g| g as i64), gas_cost_wei, error, id],
            )?;
            Ok(())
        })
        .await
    }

    /// Closes actions left mid-flight by a crash/kill of a previous run. Call after `TxSender::resume`.
    pub async fn close_interrupted_actions(&self) -> anyhow::Result<usize> {
        self.run(|c| {
            c.execute(
                "UPDATE actions SET status = 'interrupted' WHERE status IN ('simulating', 'sent')",
                [],
            )
        })
        .await
    }

    pub async fn save_pending(&self, p: PendingTx) -> anyhow::Result<()> {
        self.run(move |c| {
            c.execute(
                "INSERT OR REPLACE INTO pending_tx VALUES (1, ?, ?, ?, ?, ?, ?)",
                params![
                    p.action_id,
                    p.tx_hash,
                    p.nonce as i64,
                    p.raw,
                    p.sent_block as i64,
                    p.deadline as i64
                ],
            )?;
            Ok(())
        })
        .await
    }

    pub async fn load_pending(&self) -> anyhow::Result<Option<PendingTx>> {
        self.run(|c| {
            let mut s =
                c.prepare("SELECT action_id, tx_hash, nonce, raw, sent_block, deadline FROM pending_tx WHERE id = 1")?;
            let mut rows = s.query([])?;
            Ok(match rows.next()? {
                Some(r) => Some(PendingTx {
                    action_id: r.get(0)?,
                    tx_hash: r.get(1)?,
                    nonce: r.get::<_, i64>(2)? as u64,
                    raw: r.get(3)?,
                    sent_block: r.get::<_, i64>(4)? as u64,
                    deadline: r.get::<_, i64>(5)? as u64,
                }),
                None => None,
            })
        })
        .await
    }

    pub async fn clear_pending(&self) -> anyhow::Result<()> {
        self.run(|c| {
            c.execute("DELETE FROM pending_tx", [])?;
            Ok(())
        })
        .await
    }

    /// Runs a fixed read-only query and returns rows as JSON objects.
    pub async fn query_json(&self, sql: &'static str, args: Vec<i64>) -> anyhow::Result<Vec<Value>> {
        self.run(move |c| {
            let mut s = c.prepare(sql)?;
            let refs: Vec<&dyn ToSql> = args.iter().map(|a| a as &dyn ToSql).collect();
            let mut rows = s.query(refs.as_slice())?;
            let names = rows.as_ref().map(|s| s.column_names()).unwrap_or_default();
            let mut out = Vec::new();
            while let Some(r) = rows.next()? {
                let mut obj = Map::new();
                for (i, name) in names.iter().enumerate() {
                    obj.insert(name.clone(), to_json(r.get_ref(i)?));
                }
                out.push(Value::Object(obj));
            }
            Ok(out)
        })
        .await
    }
}

fn to_json(v: ValueRef<'_>) -> Value {
    match v {
        ValueRef::Null => Value::Null,
        ValueRef::Boolean(b) => json!(b),
        ValueRef::TinyInt(i) => json!(i),
        ValueRef::SmallInt(i) => json!(i),
        ValueRef::Int(i) => json!(i),
        ValueRef::BigInt(i) => json!(i),
        // Large integers as strings: JSON numbers lose precision above 2^53.
        ValueRef::HugeInt(i) => json!(i.to_string()),
        ValueRef::UHugeInt(i) => json!(i.to_string()),
        ValueRef::UTinyInt(i) => json!(i),
        ValueRef::USmallInt(i) => json!(i),
        ValueRef::UInt(i) => json!(i),
        ValueRef::UBigInt(i) => json!(i),
        ValueRef::Float(f) => json!(f),
        ValueRef::Double(f) => json!(f),
        ValueRef::Text(t) => json!(String::from_utf8_lossy(t)),
        other => json!(format!("{other:?}")),
    }
}

#[derive(Debug, Clone, Copy)]
pub enum EventTable {
    Deposits,
    Withdrawals,
    Rebalances,
    Swaps,
    Admin,
}

impl EventTable {
    fn insert_sql(self) -> &'static str {
        match self {
            Self::Deposits => "INSERT OR IGNORE INTO deposits VALUES (?,?,?,?,?,?,?,?)",
            Self::Withdrawals => "INSERT OR IGNORE INTO withdrawals VALUES (?,?,?,?,?,?,?,?)",
            Self::Rebalances => "INSERT OR IGNORE INTO rebalances VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            Self::Swaps => "INSERT OR IGNORE INTO swaps VALUES (?,?,?,?,?,?,?)",
            Self::Admin => "INSERT OR IGNORE INTO admin_events VALUES (?,?,?,?,?,?)",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn kv_actions_pending_roundtrip() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.kv_get("cursor").await.unwrap(), None);
        db.kv_set("cursor", "42".into()).await.unwrap();
        db.kv_set("cursor", "43".into()).await.unwrap();
        assert_eq!(db.kv_get("cursor").await.unwrap().as_deref(), Some("43"));

        let id = db
            .insert_action(1, "recenter".into(), None, Some(600), "sent")
            .await
            .unwrap();
        let id2 = db
            .insert_action(2, "skip".into(), Some("cooldown".into()), None, "skipped")
            .await
            .unwrap();
        assert!(id2 > id);
        db.update_action(id, "success", Some("0xabc".into()), Some(21000), Some("1".into()), None)
            .await
            .unwrap();
        let rows = db
            .query_json("SELECT id, status, tx_hash, gas_used FROM actions ORDER BY id", vec![])
            .await
            .unwrap();
        assert_eq!(rows[0]["status"], "success");
        assert_eq!(rows[0]["gas_used"], 21000);
        assert_eq!(rows[1]["status"], "skipped");

        assert!(db.load_pending().await.unwrap().is_none());
        let p = PendingTx {
            action_id: id,
            tx_hash: "0x1".into(),
            nonce: 7,
            raw: "0x".into(),
            sent_block: 9,
            deadline: 99,
        };
        db.save_pending(p).await.unwrap();
        assert_eq!(db.load_pending().await.unwrap().unwrap().nonce, 7);
        db.clear_pending().await.unwrap();
        assert!(db.load_pending().await.unwrap().is_none());

        // A crashed run leaves "simulating"/"sent" rows; they get closed, finished ones are untouched.
        db.insert_action(3, "recenter".into(), None, Some(600), "simulating")
            .await
            .unwrap();
        assert_eq!(db.close_interrupted_actions().await.unwrap(), 1);
        let rows = db
            .query_json("SELECT status FROM actions ORDER BY id", vec![])
            .await
            .unwrap();
        assert_eq!(rows[0]["status"], "success");
        assert_eq!(rows[2]["status"], "interrupted");
    }

    #[tokio::test]
    async fn events_are_idempotent() {
        let db = Db::open_in_memory().unwrap();
        for _ in 0..2 {
            db.insert_event(
                EventTable::Swaps,
                vec![
                    Box::new(1i64),
                    Box::new(0i32),
                    Box::new("0x".to_string()),
                    Box::new(5i64),
                    Box::new(true),
                    Box::new("10".to_string()),
                    Box::new("9".to_string()),
                ],
            )
            .await
            .unwrap();
        }
        let rows = db.query_json("SELECT count(*) AS n FROM swaps", vec![]).await.unwrap();
        assert_eq!(rows[0]["n"], 1);
    }

    #[tokio::test]
    async fn price_samples_ordered() {
        let db = Db::open_in_memory().unwrap();
        db.insert_price_sample(20, 2, -5).await.unwrap();
        db.insert_price_sample(10, 1, -4).await.unwrap();
        db.insert_price_sample(10, 1, -4).await.unwrap();
        assert_eq!(db.price_samples_since(0).await.unwrap(), vec![(10, -4), (20, -5)]);
    }
}
