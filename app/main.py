"""Task Management API.

A deliberately small app used to demo deploying to Kubernetes.
"The dev team handed us this app — our job is to deploy and operate it."

Endpoints:
  GET  /                 app info (version + which pod answered)
  GET  /tasks            list tasks
  POST /tasks            create a task  {"title": "..."}
  GET  /health           liveness  -> is the process alive?
  GET  /ready            readiness -> can we serve traffic (is the DB reachable)?
  POST /admin/break-health   make /health start failing (demo liveness restarts)
"""

import logging
import os
import socket
import sys
from contextlib import asynccontextmanager

import psycopg
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("task-api")

APP_VERSION = os.getenv("APP_VERSION", "1.0")
HOSTNAME = socket.gethostname()

# ---------------------------------------------------------------------------
# Configuration — everything comes from environment variables
# (docker-compose `environment:` locally, ConfigMap + Secret in Kubernetes).
# ---------------------------------------------------------------------------
REQUIRED_ENV = ["DB_HOST", "DB_USER", "DB_PASSWORD"]
missing = [name for name in REQUIRED_ENV if not os.getenv(name)]
if missing:
    # Crash on purpose: a misconfigured app should fail loudly at startup.
    # In Kubernetes this shows up as CrashLoopBackOff -> `kubectl logs` tells you why.
    log.error("FATAL: missing required environment variables: %s", ", ".join(missing))
    sys.exit(1)

DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "tasks")
DB_USER = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]

state = {"healthy": True}

def connect():
    return psycopg.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=3,
    )


def ensure_schema():
    # Runs on every request on purpose: if the postgres Pod is replaced (emptyDir
    # storage -> data is gone), the table is simply recreated.
    try:
        with connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS tasks (
                    id         SERIAL PRIMARY KEY,
                    title      TEXT NOT NULL,
                    done       BOOLEAN NOT NULL DEFAULT FALSE,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
    except (psycopg.errors.UniqueViolation, psycopg.errors.DuplicateTable):
        pass  # another replica created it at the same moment


def wait_for_database():
    # Don't block or crash if the DB isn't up yet: start serving anyway and
    # let the readiness probe (/ready) keep traffic away until the DB is reachable.
    try:
        ensure_schema()
    except Exception as exc:  # noqa: BLE001
        log.warning("cannot reach database %s:%s at startup: %s — /ready will report "
                    "not ready until it is reachable", DB_HOST, DB_PORT, exc)


@asynccontextmanager
async def lifespan(_app):
    wait_for_database()
    yield


app = FastAPI(title="Task Management API", version=APP_VERSION, lifespan=lifespan)


class TaskIn(BaseModel):
    title: str


@app.get("/")
def root():
    return {"app": "task-api", "version": APP_VERSION, "pod": HOSTNAME}


@app.get("/tasks")
def list_tasks():
    try:
        ensure_schema()
        with connect() as conn:
            rows = conn.execute(
                "SELECT id, title, done, created_at FROM tasks ORDER BY id"
            ).fetchall()
    except psycopg.Error as exc:
        log.error("database error: %s", exc)
        raise HTTPException(status_code=503, detail="database unavailable")
    return [
        {"id": r[0], "title": r[1], "done": r[2], "created_at": r[3].isoformat()}
        for r in rows
    ]


@app.post("/tasks", status_code=201)
def create_task(task: TaskIn):
    try:
        ensure_schema()
        with connect() as conn:
            row = conn.execute(
                "INSERT INTO tasks (title) VALUES (%s) RETURNING id, title, done, created_at",
                (task.title,),
            ).fetchone()
    except psycopg.Error as exc:
        log.error("database error: %s", exc)
        raise HTTPException(status_code=503, detail="database unavailable")
    log.info("created task id=%s title=%r", row[0], row[1])
    return {"id": row[0], "title": row[1], "done": row[2], "created_at": row[3].isoformat(),
            "served_by": HOSTNAME}


@app.get("/health")
def health():
    """Liveness: 'is this process alive and not stuck?' — never depends on the DB."""
    if not state["healthy"]:
        log.error("health check FAILING (broken on purpose via /admin/break-health)")
        return JSONResponse(status_code=500, content={"status": "unhealthy", "pod": HOSTNAME})
    return {"status": "ok", "version": APP_VERSION, "pod": HOSTNAME}


@app.get("/ready")
def ready():
    """Readiness: 'should Kubernetes send me traffic?' — yes only if the DB is reachable."""
    try:
        with connect() as conn:
            conn.execute("SELECT 1")
    except Exception as exc:  # noqa: BLE001
        log.warning("not ready: database %s:%s unreachable: %s", DB_HOST, DB_PORT, exc)
        return JSONResponse(status_code=503, content={"status": "not ready", "pod": HOSTNAME})
    return {"status": "ready", "pod": HOSTNAME}


@app.post("/admin/break-health")
def break_health():
    """Demo helper: make the liveness probe fail so Kubernetes restarts this container."""
    state["healthy"] = False
    log.warning("health check broken on purpose — liveness probe will fail from now on")
    return {"status": "health check broken", "pod": HOSTNAME}
