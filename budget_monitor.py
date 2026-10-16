"""
    Checker thread (producer)  --Queue-->  Notifier thread (consumer)
          |                                       |
          | polls Budget_Status every N seconds   | writes Budget_Alert row + prints alert
          v                                       v
        MySQL  <------------------------------- MySQL

OS concepts demonstrated
  * Background threads        -> two daemon threads run beside the Flask app
  * Scheduling                -> periodic wake-up (sleep/wait) every CHECK_INTERVAL seconds
  * Inter-thread communication-> queue.Queue (producer-consumer / bounded-buffer problem)
  * Synchronization           -> threading.Lock protects the shared 'alerted' set,
                                 threading.Event used for clean shutdown
  * Resource isolation        -> each thread owns its own DB connection
                                 (connections are not thread-safe)

Install:   pip install mysql-connector-python
Run alone: python budget_monitor.py
In Flask : from budget_monitor import start_monitor, stop_monitor
"""

import logging
import os
import queue
import threading

import mysql.connector

# ----------------------------------------------------------------------
# Configuration (override with environment variables)
# ----------------------------------------------------------------------
CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", "10"))   # seconds between scans

DB_CONFIG = {
    "host":       os.getenv("DB_HOST", "localhost"),
    "user":       os.getenv("DB_USER", "root"),
    "password":   os.getenv("DB_PASSWORD", ""),
    "database":   os.getenv("DB_NAME", "expense_analyzer"),
    # autocommit so every poll sees fresh rows (REPEATABLE READ would
    # otherwise keep showing the old snapshot)
    "autocommit": True,
}

EXCEEDED_SQL = """
    SELECT budget_id, user_id, category_name, budget_amount, spent
    FROM   Budget_Status
    WHERE  spent > budget_amount
"""

INSERT_ALERT_SQL = """
    INSERT IGNORE INTO Budget_Alert (budget_id, user_id, alert_message)
    VALUES (%s, %s, %s)
"""

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(threadName)s] %(message)s",
    datefmt="%H:%M:%S",
)

# ----------------------------------------------------------------------
# Shared state
# ----------------------------------------------------------------------
alert_queue = queue.Queue()          # checker -> notifier (IPC)
stop_event = threading.Event()       # tells both threads to finish
alerted_lock = threading.Lock()      # guards alerted_budgets
alerted_budgets = set()              # budget_ids already alerted (avoid duplicates)
_threads = []


def get_connection():
    return mysql.connector.connect(**DB_CONFIG)


def _load_existing_alerts():
    """On start-up, remember alerts raised before a restart."""
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute("SELECT budget_id FROM Budget_Alert")
        with alerted_lock:
            alerted_budgets.update(row[0] for row in cur.fetchall())
        cur.close()
    finally:
        conn.close()


# ----------------------------------------------------------------------
# Thread 1: PRODUCER - check expenses, compare with budget
# ----------------------------------------------------------------------
def checker_worker():
    conn = get_connection()
    logging.info("Checker started (interval = %ss)", CHECK_INTERVAL)
    try:
        while not stop_event.is_set():
            try:
                conn.ping(reconnect=True, attempts=3, delay=1)
                cur = conn.cursor(dictionary=True)
                cur.execute(EXCEEDED_SQL)             # Check expenses + compare budget
                rows = cur.fetchall()
                cur.close()

                for row in rows:                      # Budget exceeded?
                    with alerted_lock:                # critical section
                        if row["budget_id"] in alerted_budgets:
                            continue
                        alerted_budgets.add(row["budget_id"])
                    alert_queue.put(row)              # hand over to notifier
            except mysql.connector.Error as err:
                logging.error("DB error in checker: %s", err)

            stop_event.wait(CHECK_INTERVAL)           # sleep, but wake instantly on stop
    finally:
        conn.close()
        logging.info("Checker stopped")


# ----------------------------------------------------------------------
# Thread 2: CONSUMER - generate the alert
# ----------------------------------------------------------------------
def notifier_worker():
    conn = get_connection()
    logging.info("Notifier started")
    try:
        # keep running until stop is requested AND the queue is drained
        while not (stop_event.is_set() and alert_queue.empty()):
            try:
                row = alert_queue.get(timeout=1)      # blocks while queue is empty
            except queue.Empty:
                continue

            over_by = row["spent"] - row["budget_amount"]
            message = (
                f"Budget exceeded for {row['category_name']}: "
                f"spent {row['spent']} of {row['budget_amount']} "
                f"(over by {over_by})"
            )
            try:
                conn.ping(reconnect=True, attempts=3, delay=1)
                cur = conn.cursor()
                cur.execute(INSERT_ALERT_SQL, (row["budget_id"], row["user_id"], message))
                if cur.rowcount:                      # 0 => alert already existed
                    logging.warning("ALERT (user %s): %s", row["user_id"], message)
                cur.close()
            except mysql.connector.Error as err:
                logging.error("DB error in notifier: %s", err)
                with alerted_lock:                    # allow a retry on the next scan
                    alerted_budgets.discard(row["budget_id"])
            finally:
                alert_queue.task_done()
    finally:
        conn.close()
        logging.info("Notifier stopped")


# ----------------------------------------------------------------------
# Public API (used by Samiksha's Flask integration)
# ----------------------------------------------------------------------
def start_monitor():
    """Start the background threads (safe to call once)."""
    if _threads:
        return _threads
    stop_event.clear()
    _load_existing_alerts()
    for target, name in ((checker_worker, "Checker"), (notifier_worker, "Notifier")):
        t = threading.Thread(target=target, name=name, daemon=True)
        t.start()
        _threads.append(t)
    return _threads


def stop_monitor():
    """Ask both threads to finish and wait for them."""
    stop_event.set()
    for t in _threads:
        t.join()
    _threads.clear()


if __name__ == "__main__":
    start_monitor()
    try:
        while True:
            stop_event.wait(1)         # main thread idles; Ctrl+C to quit
    except KeyboardInterrupt:
        logging.info("Shutting down...")
        stop_monitor()