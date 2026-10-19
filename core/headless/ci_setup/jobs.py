"""The setup job: one run of "open the access point, let a person join this device to their Wi-Fi, check it worked".

A :class:`Job` is a state machine and nothing else. It does not touch the radio, run a command or read a file: events go in
(``probe_ok``, ``client_associated``, ``credentials``, ``join_ok`` ...), a :class:`Result` comes out with the new state and a
list of **effects** - plain dicts such as ``{"op": "start_ap"}`` - for the agent to carry out. Time is an injected clock.
That makes every path, including every timeout and cancellation, testable in microseconds.

States and the ways through them::

    idle -> probing -> ap_up -> client_joined -> credentials_received -> joining -> verifying -> done
                         |            |                  |                  |           |
                         +------------+------------------+--> failed        +-----------+--> rolling_back --> rolled_back | failed

``rolling_back`` is the one state added to the list in the design document: undoing a half-finished join (bring the old
profile back up, or re-open the AP) takes time and can fail, so it must be observable and bounded like any other step. Terminal
states are ``done``, ``rolled_back`` and ``failed`` and absorb every later event. ``cancel`` is accepted in every
non-terminal state (before anything was changed it ends in ``failed`` with ``error_code=cancelled``; during a join it first
rolls back). ``tick`` (or any event) applies the deadline of the current state first.

A Job is not thread-safe: the agent drives it from one thread (the portal's threads go through the agent). Secrets never enter the machine: an event carrying a field named psk, password, pin, token or key is rejected, and the SSID
of the home network is kept out of :meth:`Job.public_view`. The Wi-Fi password travels from the portal to the agent by
another channel, keyed by the job id.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Optional, Set, Tuple

from .clock import SystemClock
from .errors import ValidationError
from .validators import JOINABLE_SECURITY, validate_ifname, validate_mac, validate_phy_name, validate_ssid

IDLE, PROBING, AP_UP, CLIENT_JOINED = "idle", "probing", "ap_up", "client_joined"
CREDENTIALS_RECEIVED, JOINING, VERIFYING = "credentials_received", "joining", "verifying"
ROLLING_BACK, DONE, ROLLED_BACK, FAILED = "rolling_back", "done", "rolled_back", "failed"

STATES = (IDLE, PROBING, AP_UP, CLIENT_JOINED, CREDENTIALS_RECEIVED, JOINING, VERIFYING, ROLLING_BACK, DONE,
          ROLLED_BACK, FAILED)
TERMINAL = (DONE, ROLLED_BACK, FAILED)
JOIN_STEPS = ("saving", "stopping_ap", "associating", "dhcp")
RADIO_MODES = ("dedicated", "concurrent", "sequential")
FORBIDDEN_FIELDS = ("psk", "password", "passphrase", "pin", "token", "key", "secret", "ap_key")

# (state, event) -> the states the event can lead to. Anything not listed is rejected with "not_allowed_in_state".
TRANSITIONS: Dict[Tuple[str, str], Tuple[str, ...]] = {
    (IDLE, "start"): (PROBING,),
    (PROBING, "probe_ok"): (PROBING,),
    (PROBING, "probe_failed"): (FAILED,),
    (PROBING, "ap_started"): (AP_UP,),
    (PROBING, "ap_failed"): (FAILED,),
    (AP_UP, "client_associated"): (CLIENT_JOINED,),
    (AP_UP, "uplink_appeared"): (DONE,),
    (CLIENT_JOINED, "client_associated"): (CLIENT_JOINED,),
    (CLIENT_JOINED, "client_left"): (AP_UP, CLIENT_JOINED),
    (CLIENT_JOINED, "authenticated"): (CLIENT_JOINED,),
    (CLIENT_JOINED, "credentials"): (CREDENTIALS_RECEIVED,),
    (CLIENT_JOINED, "uplink_appeared"): (DONE,),
    (CREDENTIALS_RECEIVED, "join_started"): (JOINING,),
    (JOINING, "join_progress"): (JOINING,),
    (JOINING, "join_ok"): (VERIFYING,),
    (JOINING, "join_failed"): (ROLLING_BACK,),
    (VERIFYING, "verify_ok"): (DONE,),
    (VERIFYING, "verify_failed"): (ROLLING_BACK,),
    (ROLLING_BACK, "rollback_ok"): (ROLLED_BACK,),
    (ROLLING_BACK, "rollback_failed"): (FAILED,),
}
for _s in (PROBING, AP_UP, CLIENT_JOINED, CREDENTIALS_RECEIVED):
    TRANSITIONS[(_s, "cancel")] = (FAILED,)
for _s in (JOINING, VERIFYING):
    TRANSITIONS[(_s, "cancel")] = (ROLLING_BACK,)
EVENTS = tuple(sorted({e for (_, e) in TRANSITIONS} | {"tick"}))

# timeouts: (state, reason) -> where the machine goes when the deadline passes
TIMEOUT_TARGETS: Dict[str, str] = {
    PROBING: FAILED, AP_UP: FAILED, CLIENT_JOINED: FAILED, CREDENTIALS_RECEIVED: FAILED,
    JOINING: ROLLING_BACK, VERIFYING: ROLLING_BACK, ROLLING_BACK: FAILED,
}


@dataclass(frozen=True)
class JobConfig:
    probe_timeout_s: float = 60.0           # probing the radio and bringing the AP up
    ap_idle_timeout_s: float = 900.0        # AP up and nobody authenticated (15 minutes)
    total_timeout_s: float = 2700.0         # AP up until the credentials arrive (45 minutes)
    credentials_timeout_s: float = 30.0     # credentials accepted until the agent starts the join
    join_timeout_s: float = 90.0
    verify_timeout_s: float = 60.0
    rollback_timeout_s: float = 60.0
    max_clients: int = 8
    history_limit: int = 64


@dataclass(frozen=True)
class Result:
    accepted: bool
    reason: str                       # "ok" or why the event was rejected
    state: str                        # the state after the event
    previous: str                     # the state before it
    effects: Tuple[Dict[str, Any], ...] = ()

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def _code(value: Any, field: str = "code") -> str:
    """A short machine-readable reason: 1 to 40 characters from a-z, 0-9 and underscore."""
    if not isinstance(value, str) or not 1 <= len(value) <= 40 or not all(c in "abcdefghijklmnopqrstuvwxyz0123456789_" for c in value):
        raise ValidationError(field, "format", "a short lower-case code")
    return value


class Job:
    """One setup run. See the module docstring."""

    def __init__(self, job_id: str, clock: Any = None, config: Optional[JobConfig] = None, attempt: int = 1) -> None:
        self.job_id = job_id
        self.clock = clock if clock is not None else SystemClock()
        self.config = config or JobConfig()
        self.attempt = attempt
        self.state = IDLE
        now = self.clock.now()
        self._entered = now
        self._deadline = None  # type: Optional[float]
        self._idle_deadline = None  # type: Optional[float]
        self._total_deadline = None  # type: Optional[float]
        self.error_code = None  # type: Optional[str]
        self.outcome = None  # type: Optional[str]
        self.step = None  # type: Optional[str]
        self.authenticated = False
        self._clients = set()  # type: Set[str]
        self.ssid = None  # type: Optional[str]
        self.security = None  # type: Optional[str]
        self.hidden = False
        self.radio = {}  # type: Dict[str, str]
        self._history = []  # type: List[Tuple[float, str, str, str, Optional[str]]]

    # ------------------------------------------------------------------ helpers
    @property
    def terminal(self) -> bool:
        return self.state in TERMINAL

    def _enter(self, state: str, event: str, code: Optional[str] = None) -> None:
        now = self.clock.now()
        cfg = self.config
        prev = self.state
        self.state = state
        self._entered = now
        if state == PROBING:
            self._deadline = now + cfg.probe_timeout_s
        elif state == AP_UP:
            if self._total_deadline is None:
                self._total_deadline = now + cfg.total_timeout_s
            if not self.authenticated:
                self._idle_deadline = self._idle_deadline if self._idle_deadline is not None else now + cfg.ap_idle_timeout_s
            self._deadline = self._pre_join_deadline()
        elif state == CLIENT_JOINED:
            self._deadline = self._pre_join_deadline()
        elif state == CREDENTIALS_RECEIVED:
            self._deadline = now + cfg.credentials_timeout_s
        elif state == JOINING:
            self._deadline = now + cfg.join_timeout_s
        elif state == VERIFYING:
            self._deadline = now + cfg.verify_timeout_s
        elif state == ROLLING_BACK:
            self._deadline = now + cfg.rollback_timeout_s
        else:
            self._deadline = self._idle_deadline = self._total_deadline = None
        if prev != state or event:
            self._history.append((now, prev, state, event, code))
            del self._history[:-self.config.history_limit]

    def _pre_join_deadline(self) -> Optional[float]:
        cands = [d for d in (self._total_deadline, None if self.authenticated else self._idle_deadline) if d is not None]
        return min(cands) if cands else None

    def _result(self, accepted: bool, reason: str, previous: str, effects: List[Dict[str, Any]]) -> Result:
        return Result(accepted, reason, self.state, previous, tuple(effects))

    # ------------------------------------------------------------------ time
    def tick(self) -> Result:
        """Apply the deadline of the current state if it has passed."""
        prev = self.state
        if self.terminal or self._deadline is None or self.clock.now() < self._deadline:
            return self._result(True, "ok", prev, [])
        return self._expire()

    def _expire(self) -> Result:
        prev = self.state
        target = TIMEOUT_TARGETS[prev]
        now = self.clock.now()
        if prev in (AP_UP, CLIENT_JOINED):
            code = "timeout_total" if (self._total_deadline is not None and now >= self._total_deadline) else "timeout_idle"
        else:
            code = "timeout_" + {PROBING: "probe", CREDENTIALS_RECEIVED: "start_join", JOINING: "join",
                                 VERIFYING: "verify", ROLLING_BACK: "rollback"}[prev]
        self.error_code = code
        effects = [{"op": "rollback"}] if target == ROLLING_BACK else [{"op": "teardown"}]
        self._enter(target, "tick", code)
        return self._result(True, "timeout", prev, effects)

    # ------------------------------------------------------------------ events
    def apply(self, event: str, **data: Any) -> Result:
        """Feed one event. Never raises: a bad event is returned as ``accepted=False`` with the reason. If the current
        state's deadline had already passed, that timeout is applied first and its effects come first in the result."""
        original = self.state
        if self.terminal:
            return self._result(False, "terminal", original, [])
        carried = list(self.tick().effects)
        res = self._dispatch(event, data)
        if carried:
            res = Result(res.accepted, res.reason, res.state, original, tuple(carried) + res.effects)
        return res

    def _dispatch(self, event: str, data: Dict[str, Any]) -> Result:
        prev = self.state
        if self.terminal:
            return self._result(False, "terminal_after_timeout", prev, [])
        if not isinstance(event, str):
            return self._result(False, "bad_event", prev, [])
        if event == "tick":
            return self._result(True, "ok", prev, [])
        for name in data:
            if name in FORBIDDEN_FIELDS:
                return self._result(False, "forbidden_field", prev, [])
        if (self.state, event) not in TRANSITIONS:
            return self._result(False, "not_allowed_in_state", prev, [])
        try:
            return getattr(self, "_on_" + event)(prev, data)
        except ValidationError as exc:
            return self._result(False, "invalid:" + exc.field, prev, [])

    def _need_keys(self, data: Dict[str, Any], allowed: Tuple[str, ...]) -> None:
        for k in data:
            if k not in allowed:
                raise ValidationError(str(k)[:20], "unknown_key", "unexpected field")

    def _on_start(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ())
        self._enter(PROBING, "start")
        return self._result(True, "ok", prev, [{"op": "probe"}])

    def _on_probe_ok(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ("phy", "iface", "mode"))
        radio = {}
        if "phy" in data:
            radio["phy"] = validate_phy_name(data["phy"])
        if "iface" in data:
            radio["iface"] = validate_ifname(data["iface"])
        if "mode" in data:
            if data["mode"] not in RADIO_MODES:
                raise ValidationError("mode", "format", "unknown radio mode")
            radio["mode"] = data["mode"]
        self.radio = radio
        self.step = "starting_ap"
        self._enter(PROBING, "probe_ok")
        return self._result(True, "ok", prev, [dict({"op": "start_ap"}, **radio)])

    def _fail(self, prev: str, event: str, data: Dict[str, Any], default_code: str) -> Result:
        self._need_keys(data, ("code",))
        code = _code(data["code"]) if "code" in data else default_code
        self.error_code = code
        self._enter(FAILED, event, code)
        return self._result(True, "ok", prev, [{"op": "teardown"}])

    def _on_probe_failed(self, prev: str, data: Dict[str, Any]) -> Result:
        return self._fail(prev, "probe_failed", data, "probe_failed")

    def _on_ap_failed(self, prev: str, data: Dict[str, Any]) -> Result:
        return self._fail(prev, "ap_failed", data, "ap_failed")

    def _on_ap_started(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ())
        self.step = None
        self._enter(AP_UP, "ap_started")
        return self._result(True, "ok", prev, [{"op": "publish_credentials"}])

    def _on_client_associated(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ("mac",))
        mac = validate_mac(data.get("mac"), "mac") if "mac" in data else None
        if mac is not None:
            if mac not in self._clients and len(self._clients) >= self.config.max_clients:
                return self._result(False, "too_many_clients", prev, [])
            self._clients.add(mac)
        self._enter(CLIENT_JOINED, "client_associated")
        return self._result(True, "ok", prev, [])

    def _on_client_left(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ("mac",))
        if "mac" in data:
            self._clients.discard(validate_mac(data["mac"], "mac"))
        if not self._clients and not self.authenticated:
            self._enter(AP_UP, "client_left")
        else:
            self._history.append((self.clock.now(), self.state, self.state, "client_left", None))
            del self._history[:-self.config.history_limit]
        return self._result(True, "ok", prev, [])

    def _on_authenticated(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ())
        self.authenticated = True
        self._deadline = self._pre_join_deadline()      # the idle limit no longer applies, the total one does
        self._history.append((self.clock.now(), self.state, self.state, "authenticated", None))
        del self._history[:-self.config.history_limit]
        return self._result(True, "ok", prev, [])

    def _on_credentials(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ("ssid", "security", "hidden"))
        if not self.authenticated:
            return self._result(False, "not_authenticated", prev, [])
        ssid = validate_ssid(data.get("ssid")) if "ssid" in data else None
        if ssid is None:
            raise ValidationError("ssid", "empty", "required")
        security = data.get("security", "wpa2")
        if security not in JOINABLE_SECURITY:
            raise ValidationError("security", "format", "not joinable")
        hidden = data.get("hidden", False)
        if type(hidden) is not bool:
            raise ValidationError("hidden", "type", "boolean")
        self.ssid, self.security, self.hidden = ssid, security, hidden
        self._enter(CREDENTIALS_RECEIVED, "credentials")
        return self._result(True, "ok", prev, [{"op": "begin_join", "ssid": ssid, "security": security,
                                                "hidden": hidden}])

    def _on_join_started(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ())
        self.step = "saving"
        self._enter(JOINING, "join_started")
        return self._result(True, "ok", prev, [])

    def _on_join_progress(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ("step",))
        step = data.get("step")
        if step not in JOIN_STEPS:
            raise ValidationError("step", "format", "unknown step")
        self.step = step
        self._history.append((self.clock.now(), self.state, self.state, "join_progress", step))
        del self._history[:-self.config.history_limit]
        return self._result(True, "ok", prev, [])

    def _on_join_ok(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ())
        self.step = "verifying"
        self._enter(VERIFYING, "join_ok")
        return self._result(True, "ok", prev, [{"op": "verify"}])

    def _begin_rollback(self, prev: str, event: str, code: str) -> Result:
        self.error_code = code
        self.step = "rolling_back"
        self._enter(ROLLING_BACK, event, code)
        return self._result(True, "ok", prev, [{"op": "rollback"}])

    def _on_join_failed(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ("code",))
        return self._begin_rollback(prev, "join_failed", _code(data["code"]) if "code" in data else "join_failed")

    def _on_verify_failed(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ("code",))
        return self._begin_rollback(prev, "verify_failed", _code(data["code"]) if "code" in data else "verify_failed")

    def _on_verify_ok(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ())
        self.outcome, self.step, self.error_code = "joined", None, None
        self._enter(DONE, "verify_ok")
        return self._result(True, "ok", prev, [{"op": "finish", "linger_s": 30}])

    def _on_uplink_appeared(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ())
        if self.authenticated:
            return self._result(False, "client_active", prev, [])     # someone is mid-setup: let them finish
        self.outcome = "uplink_appeared"
        self._enter(DONE, "uplink_appeared")
        return self._result(True, "ok", prev, [{"op": "teardown"}])

    def _on_rollback_ok(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ("reopen_ap",))
        reopen = data.get("reopen_ap", False)
        if type(reopen) is not bool:
            raise ValidationError("reopen_ap", "type", "boolean")
        self.outcome, self.step = "rolled_back", None
        self._enter(ROLLED_BACK, "rollback_ok", self.error_code)
        return self._result(True, "ok", prev, [{"op": "reopen_ap"} if reopen else {"op": "teardown"}])

    def _on_rollback_failed(self, prev: str, data: Dict[str, Any]) -> Result:
        return self._fail(prev, "rollback_failed", data, "rollback_failed")

    def _on_cancel(self, prev: str, data: Dict[str, Any]) -> Result:
        self._need_keys(data, ())
        if self.state in (JOINING, VERIFYING):
            return self._begin_rollback(prev, "cancel", "cancelled")
        self.error_code, self.outcome = "cancelled", "cancelled"
        self._enter(FAILED, "cancel", "cancelled")
        return self._result(True, "ok", prev, [{"op": "teardown"}])

    # ------------------------------------------------------------------ views
    def snapshot(self) -> Dict[str, Any]:
        """Everything needed to restore the job, as JSON-serialisable data. Times are relative to now, so the snapshot
        survives a restart of the monotonic clock. It holds no secret; it does hold the home network's SSID and the clients'
        addresses, so it belongs in a root-only file, not on the portal (use :meth:`public_view` for that)."""
        now = self.clock.now()
        return {
            "v": 1, "job_id": self.job_id, "attempt": self.attempt, "state": self.state,
            "entered_ago_s": round(now - self._entered, 3),
            "deadline_in_s": None if self._deadline is None else round(self._deadline - now, 3),
            "idle_deadline_in_s": None if self._idle_deadline is None else round(self._idle_deadline - now, 3),
            "total_deadline_in_s": None if self._total_deadline is None else round(self._total_deadline - now, 3),
            "error_code": self.error_code, "outcome": self.outcome, "step": self.step,
            "authenticated": self.authenticated, "clients": sorted(self._clients),
            "ssid": self.ssid, "security": self.security, "hidden": self.hidden, "radio": dict(self.radio),
            "history": [{"ago_s": round(now - t, 3), "from": a, "to": b, "event": e, "code": c}
                        for (t, a, b, e, c) in self._history],
        }

    def public_view(self) -> Dict[str, Any]:
        """What an unauthenticated client of the portal may learn: the state and a progress word, no SSID, no addresses."""
        return {"state": self.state, "step": self.step, "error_code": self.error_code, "outcome": self.outcome,
                "needs_pin": not self.authenticated and self.state in (AP_UP, CLIENT_JOINED)}

    @classmethod
    def restore(cls, snap: Dict[str, Any], clock: Any = None, config: Optional[JobConfig] = None) -> "Job":
        """Rebuild a job from :meth:`snapshot` output (after a JSON round trip, say). Raises ValueError on a snapshot that
        is not one."""
        if not isinstance(snap, dict) or snap.get("v") != 1 or snap.get("state") not in STATES:
            raise ValueError("not a job snapshot")
        job = cls(str(snap["job_id"]), clock=clock, config=config, attempt=int(snap.get("attempt", 1)))
        now = job.clock.now()
        job.state = snap["state"]
        job._entered = now - float(snap.get("entered_ago_s", 0.0))

        def at(key: str) -> Optional[float]:
            v = snap.get(key)
            return None if v is None else now + float(v)

        job._deadline, job._idle_deadline, job._total_deadline = at("deadline_in_s"), at("idle_deadline_in_s"), at("total_deadline_in_s")
        job.error_code, job.outcome, job.step = snap.get("error_code"), snap.get("outcome"), snap.get("step")
        job.authenticated = bool(snap.get("authenticated", False))
        job._clients = set(snap.get("clients", []))
        job.ssid, job.security, job.hidden = snap.get("ssid"), snap.get("security"), bool(snap.get("hidden", False))
        job.radio = dict(snap.get("radio", {}))
        job._history = [(now - float(h["ago_s"]), h["from"], h["to"], h["event"], h.get("code"))
                        for h in snap.get("history", [])][-job.config.history_limit:]
        return job
