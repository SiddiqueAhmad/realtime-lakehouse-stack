#!/usr/bin/env python3
"""Shared harness for executable DuckLake qualification. Real processes and storage."""
from __future__ import annotations
import argparse
import concurrent.futures as cf
import contextlib
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import select
import statistics
import subprocess
import threading
import time
import traceback
import uuid

ROOT = Path(__file__).resolve().parents[2]
COMPOSE = ["docker", "compose", "-f", str(ROOT / "docker-compose.yml")]
FIELDS = [{"name": "id", "type": "int64"}, {"name": "value", "type": "int64"},
          {"name": "tenant", "type": "string"}, {"name": "secret", "type": "string"}]
CASES = {}


def case(case_id):
    def wrap(fn):
        if case_id in CASES:
            raise ValueError(f"duplicate implementation: {case_id}")
        CASES[case_id] = fn
        return fn
    return wrap


def records(ids, value=None, tenant="t0"):
    return [{"id": i, "value": i * 10 if value is None else value,
             "tenant": tenant, "secret": f"secret-{i}"} for i in ids]


def canonical(rows):
    return sorted([dict(r) for r in rows], key=lambda r: json.dumps(r, sort_keys=True))


def equal(actual, expected, message="rowset mismatch"):
    assert canonical(actual) == canonical(expected), f"{message}: actual={actual[:30]!r}; expected={expected[:30]!r}"


class OperationError(RuntimeError):
    pass


class Outcome(Exception):
    def __init__(self, status, detail):
        self.status, self.detail = status, detail


def limited(message):
    raise Outcome("KNOWN-LIMITATION", message)


def unsupported(error):
    # Never hide connectivity errors, panics, missing objects or wrong results.
    s = str(error).lower()
    return any(x in s for x in ("unsupported:", "not implemented", "not supported", "unsupported sql statement"))


def shell(args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


class Worker:
    def __init__(self, suite):
        self.suite = suite
        self.name = f"dq-{suite.run_id}-{uuid.uuid4().hex[:8]}"
        self.log = open(suite.output / f"{self.name}.jsonl", "w")
        self.err = open(suite.output / f"{self.name}.stderr", "w")
        self.lock = threading.Lock()
        args = ["docker", "run", "--rm", "-i", "--name", self.name, "--network", suite.network]
        for key, value in suite.environment.items():
            args += ["-e", f"{key}={value}"]
        self.p = subprocess.Popen(args + [suite.image], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=self.err, text=True, bufsize=1)
        self.closed = False
        suite.workers.append(self)
        try:
            self.call("hello")
        except Exception:
            self.close()
            raise

    def call(self, op, timeout=150, **kw):
        with self.lock:
            cmd = {"op": op, **kw}
            self.log.write(json.dumps({"request": cmd}) + "\n"); self.log.flush()
            self.p.stdin.write(json.dumps(cmd) + "\n"); self.p.stdin.flush()
            if not select.select([self.p.stdout], [], [], timeout)[0]:
                raise TimeoutError(f"worker {self.name}: {op} did not complete in {timeout}s")
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError(f"worker {self.name} exited during {op}; inspect its stderr artifact")
            response = json.loads(line)
            self.log.write(json.dumps({"response": response}) + "\n"); self.log.flush()
            if not response.get("ok"):
                raise OperationError(response.get("error", "worker returned no error detail"))
            return response["result"]

    def crash(self):
        shell(["docker", "kill", "--signal", "KILL", self.name])
        self.p.wait(timeout=20)
        assert self.p.returncode != 0, "killed worker incorrectly reported success"

    def close(self):
        if self.closed:
            return
        self.closed = True
        with contextlib.suppress(Exception):
            self.p.stdin.close()
            self.p.wait(timeout=10)
        if self.p.poll() is None:
            subprocess.run(["docker", "rm", "-f", self.name], capture_output=True)
            self.p.kill(); self.p.wait()
        self.log.close(); self.err.close()


class Suite:
    def __init__(self, lane, output):
        self.lane, self.run_id = lane, uuid.uuid4().hex[:12]
        self.database = f"ducklake_qualification_{lane}_{self.run_id}"
        self.output = output / lane
        self.output.mkdir(parents=True, exist_ok=True)
        self.workers = []
        self.current_case = "setup"
        self.details = {}
        self.image = f"ducklake-qualification:{lane}"
        self.root = f"s3://lake/_ducklake_qualification/{self.run_id}/{lane}"
        pgid = shell(COMPOSE + ["ps", "-q", "postgres"], cwd=ROOT).stdout.strip()
        if not pgid:
            raise RuntimeError("Postgres service is not started")
        networks = json.loads(shell(["docker", "inspect", pgid]).stdout)[0]["NetworkSettings"]["Networks"]
        if len(networks) != 1:
            raise RuntimeError("expected one Compose network; refuse to guess a network")
        self.network = next(iter(networks))
        self.environment = {"DATABASE_URL": f"postgresql://governance:governance@postgres:5432/{self.database}",
                            "QUALIFICATION_ONLY": "1", "QUALIFICATION_DATA_PATH": self.root,
                            "AWS_ENDPOINT_URL": "http://minio:9000", "AWS_ACCESS_KEY_ID": "minioadmin",
                            "AWS_SECRET_ACCESS_KEY": "minioadmin123"}
        self.pg(f'CREATE DATABASE "{self.database}";', "postgres")
        try:
            self.main = Worker(self)
            self.copy_build_evidence()
        except Exception:
            self.close()
            raise

    def pg(self, sql, database=None):
        return shell(COMPOSE + ["exec", "-T", "postgres", "psql", "-X", "-v", "ON_ERROR_STOP=1",
                                "-U", "governance", "-d", database or self.database, "-At"], input=sql, cwd=ROOT).stdout

    def copy_build_evidence(self):
        container = shell(["docker", "create", "--entrypoint", "/bin/true", self.image]).stdout.strip()
        try:
            for filename in ["Cargo.lock", "dependencies.json", "rustc.txt", "governed-app-Cargo.toml"]:
                shell(["docker", "cp", f"{container}:/usr/share/qualification/{filename}", str(self.output / filename)])
            self.graph = json.loads((self.output / "dependencies.json").read_text())
        finally:
            shell(["docker", "rm", container])

    def worker(self):
        return Worker(self)

    def init(self, suffix=""):
        cat = self.current_case.lower().replace("-", "_") + suffix
        self.main.call("init", catalog=cat)
        return cat

    def call(self, op, cat, worker=None, **kw):
        return (worker or self.main).call(op, catalog=cat, **kw)

    def write(self, cat, rows, mode="replace", fields=None, table="events", worker=None, **kw):
        return self.call("write", cat, worker, table=table, fields=fields or FIELDS, rows=rows, mode=mode, **kw)

    def begin(self, w, cat, rows, mode="replace", fields=None, table="events"):
        return self.call("begin", cat, w, token="pending", table=table, fields=fields or FIELDS, rows=rows, mode=mode)

    def finish(self, w, cat):
        return self.call("finish", cat, w, token="pending")

    def query(self, cat, sql="SELECT * FROM events ORDER BY id", worker=None, **kw):
        return self.call("query", cat, worker, sql=sql, **kw)

    def rows(self, cat, worker=None, **kw):
        return self.query(cat, worker=worker, **kw)["rows"]

    def state(self, cat):
        return self.call("state", cat)

    def exact(self, cat, expected):
        equal(self.rows(cat), expected)
        # A genuinely fresh process/client, not the writer's cached provider.
        w = self.worker()
        try:
            equal(self.rows(cat, w), expected, "fresh reader differs")
        finally:
            w.close()

    def live_files(self, cat, table="events"):
        state = self.state(cat); head = state["head"]
        return [f for f in state["files"] if f["table_name"] == table and f["begin_snapshot"] <= head
                and (f.get("end_snapshot") is None or head < f["end_snapshot"])]

    def columns(self, cat):
        return {c["column_name"]: c["column_id"] for c in self.state(cat)["columns"]
                if c["table_name"] == "events" and c.get("end_snapshot") is None}

    def parallel(self, jobs):
        # Future.result propagates every exception. No fire-and-forget workers.
        barrier = threading.Barrier(len(jobs))
        def run(fn):
            barrier.wait(timeout=30)
            return fn()
        with cf.ThreadPoolExecutor(max_workers=len(jobs)) as pool:
            futures = [pool.submit(run, fn) for fn in jobs]
            results = []
            for future in futures:
                try:
                    results.append(future.result(timeout=180))
                except OperationError as error:
                    results.append(error)
            return results

    def concurrent_appends(self, count, iterations=1):
        cat = self.init(f"_w{count}")
        self.write(cat, records([0]))
        ws = [self.worker() for _ in range(count)]
        expected = records([0]); snapshots = set()
        for iteration in range(iterations):
            additions = [records([1 + iteration * count + i]) for i in range(count)]
            # All writes are prepared before any can finish.
            for w, rows in zip(ws, additions):
                self.begin(w, cat, rows, "append")
            results = self.parallel([lambda w=w: self.finish(w, cat) for w in ws])
            for result in results:
                if isinstance(result, Exception):
                    raise result
                assert result["snapshot"] not in snapshots, "duplicate successful snapshot id"
                snapshots.add(result["snapshot"])
            expected += [row for group in additions for row in group]
            equal(self.rows(cat), expected)
        self.exact(cat, expected)
        for w in ws:
            w.close()
        return {"writers": count, "iterations": iterations, "successful_writes": len(snapshots)}

    def conflict(self, suffix=""):
        cat = self.init(suffix); self.write(cat, records([0]))
        ws = [self.worker(), self.worker()]
        for i, w in enumerate(ws):
            self.begin(w, cat, records([10 + i]))
        results = self.parallel([lambda w=w: self.finish(w, cat) for w in ws])
        winners = [i for i, result in enumerate(results) if not isinstance(result, Exception)]
        errors = [str(result) for result in results if isinstance(result, Exception)]
        self.details[cat] = {"winners": winners, "errors": errors, "state": self.state(cat)}
        assert len(winners) == 1 and len(errors) == 1, "same-base Replace must yield one winner and one conflict, not two acknowledgements"
        assert "conflict" in errors[0].lower(), f"not a retryable conflict: {errors}"
        self.exact(cat, records([10 + winners[0]]))
        for w in ws:
            w.close()

    def governed(self, cat, sql="SELECT * FROM events ORDER BY id", **kw):
        cedar = ('@id("tenant") @target_table("events") @filter_type("row_filter") '
                 'permit(principal,action,resource) when { resource.tenant == principal.tenant };\n'
                 '@id("secret") @target_table("events") @filter_type("column_mask") @column("secret") '
                 'forbid(principal,action,resource) when { principal.role == "reader" };')
        return self.query(cat, sql, governed=True, table="events", cedar=cedar, **kw)

    def cleanup_workers(self):
        for w in self.workers[1:]:
            w.close()
        self.workers = self.workers[:1]

    def close(self):
        for w in self.workers:
            w.close()
        # Guard database deletion independently of how the database was created.
        assert self.database.startswith("ducklake_qualification_") and self.run_id in self.database
        self.pg(f'DROP DATABASE "{self.database}" WITH (FORCE);', "postgres")
