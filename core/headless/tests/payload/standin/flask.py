"""A stand-in for the part of Flask that setup_service.py uses. TEST-ONLY.

Used by core/headless/tests/payload only when the real Flask is not importable (a stock macOS has none; CI
installs python3-flask and then this file is never loaded). It reproduces the behaviour the tests depend on:
route registration (several routes per view, methods), before_request hooks, a test client with get/post,
`request.is_json` / `get_json(silent=...)` / `form.to_dict()` / `headers.get`, `jsonify`, views returning a
Response, a (body, status) tuple or a string, an unhandled exception becoming a bare 500, and
MAX_CONTENT_LENGTH becoming a 413.

It is deliberately small. Anything setup_service.py starts to use beyond this will fail loudly here
(AttributeError) rather than pass silently; add it here AND check that real Flask behaves the same way.
"""
import contextlib
import json as _json
import threading
import urllib.parse

__version__ = 'standin'
IS_STANDIN = True


class HTTPException(Exception):
    code = 500


class BadRequest(HTTPException):
    code = 400


class UnsupportedMediaType(HTTPException):
    code = 415


class _Headers:
    def __init__(self, items=None):
        self._d = {str(k).lower(): v for k, v in (items or {}).items()}

    def get(self, key, default=None):
        return self._d.get(str(key).lower(), default)

    def __getitem__(self, key):
        return self._d[str(key).lower()]

    def __contains__(self, key):
        return str(key).lower() in self._d

    def items(self):
        return self._d.items()


class _Form:
    def __init__(self, mapping):
        self._m = dict(mapping)

    def to_dict(self):
        return dict(self._m)

    def get(self, key, default=None):
        return self._m.get(key, default)

    def __bool__(self):
        return bool(self._m)


class _RequestData:
    def __init__(self, method, path, headers, body, form):
        self.method = method
        self.path = path
        self.headers = _Headers(headers)
        self.data = body
        self.form = _Form(form)
        self.content_length = len(body)

    @property
    def mimetype(self):
        return (self.headers.get('Content-Type') or '').split(';')[0].strip().lower()

    @property
    def is_json(self):
        mt = self.mimetype
        return mt == 'application/json' or (mt.startswith('application/') and mt.endswith('+json'))

    def get_json(self, force=False, silent=False, cache=True):
        if not (self.is_json or force):
            if silent:
                return None
            raise UnsupportedMediaType('Content-Type must be application/json')
        try:
            return _json.loads(self.data.decode('utf-8'))
        except Exception:
            if silent:
                return None
            raise BadRequest('Failed to decode JSON object')

    def get_data(self):
        return self.data


_local = threading.local()


class _RequestProxy:
    def __getattr__(self, name):
        current = getattr(_local, 'request', None)
        if current is None:
            raise RuntimeError('Working outside of request context.')
        return getattr(current, name)


request = _RequestProxy()


class Response:
    def __init__(self, data=b'', status=200, mimetype='text/html', headers=None):
        if isinstance(data, str):
            data = data.encode('utf-8')
        self.data = data
        self.status_code = status
        self.mimetype = mimetype
        self.headers = _Headers(headers)

    def get_json(self, silent=False, force=False):
        try:
            return _json.loads(self.data.decode('utf-8'))
        except Exception:
            if silent:
                return None
            raise

    @property
    def text(self):
        return self.data.decode('utf-8', errors='replace')

    def get_data(self, as_text=False):
        return self.text if as_text else self.data


def jsonify(*args, **kwargs):
    if args and kwargs:
        raise TypeError('jsonify() behavior undefined when passed both args and kwargs')
    payload = args[0] if len(args) == 1 else (list(args) if args else dict(kwargs))
    return Response(_json.dumps(payload), 200, 'application/json')


def _make_response(rv):
    status = None
    if isinstance(rv, tuple):
        if len(rv) == 2:
            rv, status = rv
        elif len(rv) == 3:
            rv, status, _headers = rv
        else:
            raise TypeError('bad view return tuple')
    if isinstance(rv, Response):
        response = rv
    elif isinstance(rv, (str, bytes)):
        response = Response(rv)
    elif isinstance(rv, dict):
        response = jsonify(rv)
    else:
        raise TypeError(f'The view function did not return a valid response: {type(rv).__name__}')
    if status is not None:
        response.status_code = status
    return response


class _TestClient:
    def __init__(self, app):
        self.app = app

    def open(self, method, path, json=None, data=None, headers=None, content_type=None):
        headers = dict(headers or {})
        form = {}
        body = b''
        if json is not None:
            body = _json.dumps(json).encode('utf-8')
            headers.setdefault('Content-Type', 'application/json')
        elif isinstance(data, dict):
            form = {k: v for k, v in data.items()}
            body = urllib.parse.urlencode(form).encode('utf-8')
            headers.setdefault('Content-Type', content_type or 'application/x-www-form-urlencoded')
        elif data is not None:
            body = data if isinstance(data, bytes) else str(data).encode('utf-8')
        if content_type:
            headers['Content-Type'] = content_type
        return self.app._dispatch(method, path, headers, body, form)

    def get(self, path, **kw):
        return self.open('GET', path, **kw)

    def post(self, path, **kw):
        return self.open('POST', path, **kw)


class Flask:
    def __init__(self, import_name):
        self.import_name = import_name
        self.config = {}
        self._routes = {}
        self._before = []

    def route(self, rule, methods=None):
        methods = [m.upper() for m in (methods or ['GET'])]

        def decorator(view):
            for method in methods:
                self._routes[(method, rule)] = view
            return view
        return decorator

    def before_request(self, func):
        self._before.append(func)
        return func

    @contextlib.contextmanager
    def app_context(self):
        yield self

    def test_client(self):
        return _TestClient(self)

    def _dispatch(self, method, path, headers, body, form):
        limit = self.config.get('MAX_CONTENT_LENGTH')
        if limit is not None and len(body) > limit:
            return Response('Request Entity Too Large', 413)
        clean_path = path.split('?', 1)[0]
        view = self._routes.get((method, clean_path))
        if view is None:
            known = {rule for (_m, rule) in self._routes}
            return Response('Method Not Allowed' if clean_path in known else 'Not Found', 405 if clean_path in known else 404)
        _local.request = _RequestData(method, clean_path, headers, body, form)
        try:
            for hook in self._before:
                early = hook()
                if early is not None:
                    return _make_response(early)
            return _make_response(view())
        except HTTPException as exc:
            return Response(str(exc), exc.code)
        except Exception:
            return Response('Internal Server Error', 500)
        finally:
            _local.request = None
