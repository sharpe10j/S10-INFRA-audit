#!/usr/bin/env python3
# validate_batched_3.py — batched validator; JSON outputs (arrays), not JSONL

import argparse
import json
import sys
import time
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from typing import Dict, Iterable, List, Tuple, Optional
from uuid import uuid4

from confluent_kafka import Consumer, TopicPartition, KafkaError
from clickhouse_driver import Client

# ------ Imports for sending summary email after validation --------
from dotenv import load_dotenv
import os

# Prefer an external path, then fall back to local ".env"
dotenv_path = os.getenv("VALIDATION_DOTENV", "/etc/sharpe10/validation.env")
loaded = load_dotenv(dotenv_path)
if not loaded:
    load_dotenv()  # fallback to a local .env if present
    
import os
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

# ---------- Helpers ----------

DATETIME_FMT = "%Y-%m-%d %H:%M:%S"  # human arg only; Kafka ts=ms; payload 'datetime'=ns

def parse_start_time(arg: str) -> int:
    s = arg.strip()
    if s.isdigit():
        return int(s)
    dt = datetime.strptime(s, DATETIME_FMT).replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)

def payload_to_key(obj: dict) -> Tuple:
    # schema: ["datetime","event_type","ticker","price","quantity","exchange","conditions"]
    return (
        int(obj["datetime"]),
        str(obj["event_type"]),
        str(obj["ticker"]),
        int(obj["price"]),
        int(obj["quantity"]),
        str(obj["exchange"]),
        str(obj["conditions"]),
    )

def rows_to_keys(rows: Iterable[Tuple]) -> Iterable[Tuple]:
    for r in rows:
        yield (
            int(r[0]),
            str(r[1]),
            str(r[2]),
            int(r[3]),
            int(r[4]),
            str(r[5]),
            str(r[6]),
        )

def min_max_payload_ns(objs: List[dict]) -> Tuple[int, int]:
    vals = [int(o["datetime"]) for o in objs]
    return min(vals), max(vals)

# ---------- Email ----------

def send_validation_email(*, success: bool, started_at: datetime, finished_at: datetime,
                          rows_validated: int, rows_matched: int, rows_mismatched: int,
                          topic: str, notes: str = "") -> None:
    host = os.getenv("SMTP_HOST", "smtp.gmail.com")
    port = int(os.getenv("SMTP_PORT", "587"))
    user = os.getenv("SMTP_USER")
    pwd  = os.getenv("SMTP_PASS")
    to_str = os.getenv("SMTP_TO", "")
    recipients = [a.strip() for a in to_str.split(",") if a.strip()]
    if not (user and pwd and recipients):
        print("[Email] Skipping: missing SMTP envs"); return

    from_name = os.getenv("SMTP_FROM_NAME", "Validation Bot")
    to_name   = os.getenv("SMTP_TO_NAME", "Team")

    status = "SUCCESS" if success else "FAILURE"
    subject = f"[Validation {status}] {started_at.date()} topic={topic} rows={rows_validated} mismatches={rows_mismatched}"

    dur_s = (finished_at - started_at).total_seconds()
    text = f"""Validation summary
Status: {status}
Topic: {topic}
Rows validated: {rows_validated}
Rows matched: {rows_matched}
Rows mismatched: {rows_mismatched}
Started: {started_at.isoformat()}
Finished: {finished_at.isoformat()}
Duration (s): {dur_s:.2f}
Notes: {notes or "-"}
"""
    html = f"""<html><body>
    <h3>Validation summary</h3>
    <table cellpadding="4">
      <tr><td><b>Status</b></td><td>{status}</td></tr>
      <tr><td><b>Topic</b></td><td>{topic}</td></tr>
      <tr><td><b>Rows validated</b></td><td>{rows_validated:,}</td></tr>
      <tr><td><b>Rows matched</b></td><td>{rows_matched:,}</td></tr>
      <tr><td><b>Rows mismatched</b></td><td><b>{rows_mismatched:,}</b></td></tr>
      <tr><td><b>Started</b></td><td>{started_at.isoformat()}</td></tr>
      <tr><td><b>Finished</b></td><td>{finished_at.isoformat()}</td></tr>
      <tr><td><b>Duration (s)</b></td><td>{dur_s:.2f}</td></tr>
      <tr><td><b>Notes</b></td><td>{notes or "-"}</td></tr>
    </table>
    </body></html>"""

    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = f"{from_name} <{user}>"
    msg["To"] = ", ".join(recipients)
    msg.attach(MIMEText(text, "plain"))
    msg.attach(MIMEText(html, "html"))

    try:
        with smtplib.SMTP(host, port) as s:
            s.starttls()
            s.login(user, pwd)
            s.sendmail(user, recipients, msg.as_string())
        print("[Email] Sent validation summary.")
    except Exception as e:
        print(f"[Email] Failed to send: {e}")

# ---------- Kafka helpers ----------

def topic_partitions(consumer: Consumer, topic: str) -> List[int]:
    md = consumer.list_topics(topic=topic, timeout=5.0)
    if topic not in md.topics:
        raise RuntimeError(f"Topic '{topic}' not found in metadata.")
    return [p.id for p in md.topics[topic].partitions.values()]

def seek_to_timestamp(consumer: Consumer, topic: str, partitions: List[int], ts_ms: int) -> None:
    tps = [TopicPartition(topic, p, ts_ms) for p in partitions]
    looked = consumer.offsets_for_times(tps, timeout=10.0)
    assigned: List[TopicPartition] = []
    for tp in looked:
        if tp.offset is None or tp.offset < 0:
            low, _ = consumer.get_watermark_offsets(TopicPartition(topic, tp.partition), timeout=10.0)
            tp.offset = low
        assigned.append(tp)
    consumer.assign(assigned)

def last_timestamp_ms_for_partition(consumer: Consumer, topic: str, partition: int) -> Optional[int]:
    low, high = consumer.get_watermark_offsets(TopicPartition(topic, partition), timeout=10.0)
    if high is None or high == low:
        return None
    tp = TopicPartition(topic, partition, high - 1)
    consumer.assign([tp])
    msg = consumer.poll(timeout=5.0)
    if msg is None or msg.error():
        return None
    _, ts = msg.timestamp()
    if ts is None or ts < 0:
        return None
    return int(ts)

def topic_stop_time_ms(consumer: Consumer, topic: str, partitions: List[int]) -> Optional[int]:
    latest: List[int] = []
    for p in partitions:
        ts = last_timestamp_ms_for_partition(consumer, topic, p)
        if ts is not None:
            latest.append(ts)
    return max(latest) if latest else None

def compute_stop_offsets(consumer: Consumer, topic: str, parts: List[int], stop_ms: int) -> Dict[int, int]:
    query_ts = stop_ms + 1  # exclusive upper bound
    tps = [TopicPartition(topic, p, query_ts) for p in parts]
    looked = consumer.offsets_for_times(tps, timeout=10.0)
    stops: Dict[int, int] = {}
    for tp in looked:
        low, high = consumer.get_watermark_offsets(TopicPartition(topic, tp.partition), timeout=10.0)
        if tp.offset is None or tp.offset < 0:
            stops[tp.partition] = high
        else:
            stops[tp.partition] = tp.offset
    return stops

def reached_stop_offsets(consumer: Consumer, stop_offsets: Dict[int, int]) -> bool:
    assignments = consumer.assignment()
    if not assignments:
        return False
    positions = consumer.position(assignments)
    for pos in positions:
        need = stop_offsets.get(pos.partition, None)
        have = pos.offset if pos.offset is not None else -1
        if need is None or have < need:
            return False
    return True

# ---------- ClickHouse ----------

def ch_client(args) -> Client:
    return Client(
        host=args.ch_host,
        port=args.ch_port,
        user=args.ch_user,
        password=args.ch_password,
        database=args.ch_database,
        settings={"use_numpy": False},
    )

def ch_query_rows(client: Client, table: str, start_ns: int, end_ns: int) -> List[Tuple]:
    q = f"""
    SELECT
        toUnixTimestamp64Nano(datetime) AS dt_ns,
        event_type, ticker, price, quantity, exchange, conditions
    FROM {table}
    WHERE toUnixTimestamp64Nano(datetime) BETWEEN %(s)s AND %(e)s
    """
    return client.execute(q, params={"s": start_ns, "e": end_ns})

# ---------- State ----------

@dataclass
class RunState:
    ch_min_scanned_ns: Optional[int] = None
    ch_watermark_ns: Optional[int] = None
    pending_ch: Counter = None
    missing_in_ch: Counter = None
    total_kafka: int = 0
    total_ch_window: int = 0
    matched_via_overflow: int = 0
    matched_direct: int = 0
    # new: in-memory JSON arrays for outputs
    bad_rows_list: List[dict] = None
    ch_query_windows_list: List[dict] = None
    details_list: List[dict] = None

    def __post_init__(self):
        if self.pending_ch is None:
            self.pending_ch = Counter()
        if self.missing_in_ch is None:
            self.missing_in_ch = Counter()
        if self.bad_rows_list is None:
            self.bad_rows_list = []
        if self.ch_query_windows_list is None:
            self.ch_query_windows_list = []
        if self.details_list is None:
            self.details_list = []

# ---------- Batch processing ----------

def process_batch(
    client: Client,
    args,
    state: RunState,
    batch_msgs: List[Tuple[object, dict]],
):
    if not batch_msgs:
        return

    # Split good/bad rows
    good_objs: List[dict] = []
    for msg, obj in batch_msgs:
        if not isinstance(obj, dict):
            state.bad_rows_list.append({
                "reason": "not_json_object",
                "topic": msg.topic(), "partition": msg.partition(), "offset": msg.offset(),
                "raw_sample": str(obj)[:200],
            })
            continue
        if "datetime" not in obj:
            state.bad_rows_list.append({
                "reason": "missing_datetime",
                "topic": msg.topic(), "partition": msg.partition(), "offset": msg.offset(),
                "payload": obj,
            })
            continue
        try:
            _ = int(obj["datetime"])
        except Exception:
            state.bad_rows_list.append({
                "reason": "invalid_datetime",
                "topic": msg.topic(), "partition": msg.partition(), "offset": msg.offset(),
                "payload": obj,
            })
            continue
        good_objs.append(obj)

    if not good_objs:
        batch_msgs.clear()
        return

    batch_start_ns, batch_end_ns = min_max_payload_ns(good_objs)

    # Backfill unseen slice into pending_ch
    if state.ch_min_scanned_ns is None:
        state.ch_min_scanned_ns = batch_start_ns
    elif batch_start_ns < state.ch_min_scanned_ns:
        backfill_end = min(state.ch_min_scanned_ns - 1, batch_end_ns)
        if batch_start_ns <= backfill_end:
            bf_rows = ch_query_rows(client, args.table, batch_start_ns, backfill_end)
            state.total_ch_window += len(bf_rows)
            for k in rows_to_keys(bf_rows):
                state.pending_ch[k] += 1
            state.ch_min_scanned_ns = batch_start_ns

    # Watermark-aware CH range (avoid re-scanning)
    if state.ch_watermark_ns is None:
        ch_start_ns = batch_start_ns
    else:
        ch_start_ns = max(batch_start_ns, state.ch_watermark_ns + 1)

    # Perform CH query and log it
    if ch_start_ns <= batch_end_ns:
        ch_rows = ch_query_rows(client, args.table, ch_start_ns, batch_end_ns)
    else:
        ch_rows = []

    state.ch_query_windows_list.append({
        "window_start_ns": ch_start_ns,
        "window_end_ns": batch_end_ns,
        "row_count": len(ch_rows),
        "table": args.table,
    })

    state.total_ch_window += len(ch_rows)

    # Normalize → counters
    kafka_keys = [payload_to_key(o) for o in good_objs]
    ch_keys = list(rows_to_keys(ch_rows))

    kcnt = Counter(kafka_keys)
    ccnt = Counter(ch_keys)
    state.total_kafka += sum(kcnt.values())

    # Spend from pending CH overflow first
    for key, k_amount in list(kcnt.items()):
        if k_amount <= 0:
            continue
        avail = state.pending_ch.get(key, 0)
        if avail > 0:
            use = min(k_amount, avail)
            kcnt[key] -= use
            state.pending_ch[key] -= use
            if state.pending_ch[key] == 0:
                del state.pending_ch[key]
            state.matched_via_overflow += use

    # Compare within this window
    all_keys = set(kcnt.keys()) | set(ccnt.keys())
    for key in all_keys:
        kv = kcnt.get(key, 0)
        cv = ccnt.get(key, 0)
        if kv > cv:
            state.missing_in_ch[key] += (kv - cv)
        elif cv > kv:
            state.pending_ch[key] += (cv - kv)

    state.matched_direct += sum(min(kcnt.get(k, 0), ccnt.get(k, 0)) for k in all_keys)

    # Advance CH watermark; clear batch
    state.ch_watermark_ns = max(state.ch_watermark_ns or batch_end_ns, batch_end_ns)
    batch_msgs.clear()

# ---------- Core run ----------

def run_validation(args):
    t0 = time.perf_counter()
    start_dt = datetime.now(timezone.utc)

    consumer = Consumer({
        "bootstrap.servers": args.broker,
        "group.id": f"batch-validator-{uuid4()}",
        "enable.auto.commit": False,
        "enable.partition.eof": True,
        "auto.offset.reset": "earliest",
        "max.poll.interval.ms": 300000,
        "session.timeout.ms": 45000,
        "fetch.max.bytes": 64 * 1024 * 1024,
        "queued.min.messages": 100000,
    })
    consumer.subscribe([args.topic])

    parts = topic_partitions(consumer, args.topic)
    start_ms = parse_start_time(args.start_time)
    seek_to_timestamp(consumer, args.topic, parts, start_ms)

    stop_ms = topic_stop_time_ms(consumer, args.topic, parts)
    seek_to_timestamp(consumer, args.topic, parts, start_ms)

    if stop_ms is None:
        print("Topic appears to be empty. Exiting.")
        consumer.close()
        return

    stop_offsets = compute_stop_offsets(consumer, args.topic, parts, stop_ms)
    print(f"[Init] Start >= {start_ms} ms, stop {stop_ms} ms (inclusive).")
    print(f"[Init] Stop offsets: {stop_offsets}")

    client = ch_client(args)
    state = RunState()

    batch_msgs: List[Tuple[object, dict]] = []

    while True:
        msg = consumer.poll(timeout=0.05)
        if msg is None:
            if reached_stop_offsets(consumer, stop_offsets):
                process_batch(client, args, state, batch_msgs)
                print("[Stop] Reached all stop offsets; exiting.")
                break
            continue

        if msg.error():
            if msg.error().code() == KafkaError._PARTITION_EOF:
                if reached_stop_offsets(consumer, stop_offsets):
                    process_batch(client, args, state, batch_msgs)
                    print("[Stop] EOF and reached stop offsets; exiting.")
                    break
                continue
            else:
                print(f"[Warn] Kafka error: {msg.error()}")
                continue

        # Decode payload JSON; log invalid JSON as bad row
        try:
            obj = json.loads(msg.value().decode("utf-8"))
        except Exception as e:
            state.bad_rows_list.append({
                "reason": "invalid_json",
                "topic": msg.topic(), "partition": msg.partition(), "offset": msg.offset(),
                "error": str(e)
            })
            continue

        batch_msgs.append((msg, obj))

        if len(batch_msgs) >= args.batch_size:
            process_batch(client, args, state, batch_msgs)
            if args.commit:
                try:
                    consumer.commit(asynchronous=False)
                except Exception as e:
                    print(f"[Warn] Commit failed: {e}")
            if reached_stop_offsets(consumer, stop_offsets):
                print("[Stop] Reached all stop offsets after batch; exiting.")
                break

    consumer.close()

    # --- Final summary / details ---
    missing_total = sum(state.missing_in_ch.values())
    extra_total = sum(state.pending_ch.values())
    matched_total = state.matched_direct + state.matched_via_overflow
    mismatch_total = missing_total + extra_total
    elapsed = time.perf_counter() - t0

    end_dt = datetime.now(timezone.utc)

    send_validation_email(
        success=True,
        started_at=start_dt,
        finished_at=end_dt,
        rows_validated=state.total_kafka,
        rows_matched=matched_total,
        rows_mismatched=mismatch_total,
        topic=args.topic,
        notes=f"batch_size={args.batch_size}, commit={bool(args.commit)}"
    )

    # --- Human-readable console summary ---
    elapsed_td = timedelta(seconds=round(elapsed, 3))
    print("\n===== Validation Summary =====")
    print(f"Kafka messages consumed: {state.total_kafka}")
    print(f"ClickHouse rows scanned (summed windows): {state.total_ch_window}")
    print(f"Total matched: {matched_total}")
    print(f"Total mismatched: {mismatch_total}")
    print(f"Matched directly (same window): {state.matched_direct}")
    print(f"Matched via CH overflow from previous windows: {state.matched_via_overflow}")
    print(f"Still missing in ClickHouse: {missing_total}")
    print(f"Still extra in ClickHouse: {extra_total}")
    print(f"Elapsed: {elapsed_td} ({elapsed:.3f}s)")
    print("Done.")

    # Summary as a single JSON object
    if args.summary:
        with open(args.summary, "w") as f:
            json.dump({
                "kafka_messages_consumed": state.total_kafka,
                "clickhouse_rows_scanned": state.total_ch_window,
                "total_matched": matched_total,
                "total_mismatched": mismatch_total,
                "matched_direct": state.matched_direct,
                "matched_via_overflow": state.matched_via_overflow,
                "still_missing_in_clickhouse": missing_total,
                "still_extra_in_clickhouse": extra_total,
                "elapsed_seconds": round(elapsed, 3),
            }, f, indent=2)

    # Details as JSON array (was JSONL)
    if args.details:
        # limit samples like before
        out = []
        def add_samples(counter: Counter, title: str, limit: int = 100):
            written = 0
            for key, cnt in counter.items():
                out.append({"title": title, "record": key, "count": cnt})
                written += 1
                if written >= limit:
                    break
        add_samples(state.missing_in_ch, "Missing in ClickHouse")
        add_samples(state.pending_ch, "Extra in ClickHouse (unmatched)")
        with open(args.details, "w") as f:
            json.dump(out, f, indent=2)

    # Bad rows + CH query windows as JSON arrays (was JSONL)
    if args.bad_rows:
        with open(args.bad_rows, "w") as f:
            json.dump(state.bad_rows_list, f, indent=2)

    if args.ch_query_log:
        with open(args.ch_query_log, "w") as f:
            json.dump(state.ch_query_windows_list, f, indent=2)

    print("Done.")

# ---------- CLI ----------

def main():
    ap = argparse.ArgumentParser(description="Batched Kafka ↔ ClickHouse validator with JSON outputs.")
    ap.add_argument("--broker", required=True)
    ap.add_argument("--topic", required=True)
    ap.add_argument("--group", default="validator_group")
    ap.add_argument("--start-time", required=True,
                    help=f"Start time as epoch ms OR UTC datetime in '{DATETIME_FMT}'")
    ap.add_argument("--batch-size", type=int, default=10000)
    ap.add_argument("--commit", action="store_true")

    ap.add_argument("--ch-host", required=True)
    ap.add_argument("--ch-port", type=int, default=9000)
    ap.add_argument("--ch-user", default="default")
    ap.add_argument("--ch-password", default="")
    ap.add_argument("--ch-database", required=True)
    ap.add_argument("--table", required=True)

    # outputs (now *.json)
    ap.add_argument("--summary", default="validation_summary.json")
    ap.add_argument("--details", default="validation_details.json",
                    help="JSON array of sampled mismatch records")
    ap.add_argument("--bad-rows", default="bad_rows.json",
                    help="JSON array of malformed/missing-datetime rows")
    ap.add_argument("--ch-query-log", default="ch_query_windows.json",
                    help="JSON array of each ClickHouse query window and row_count")
    args = ap.parse_args()

    try:
        run_validation(args)
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        sys.exit(130)

if __name__ == "__main__":
    main()

