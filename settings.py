# -*- coding: utf-8 -*-
# ---------------------------------------------------------------------------
# RapidPro v9 settings overlay for the Docker/Helm setup.
# Fully env-driven: capabilities are baked here, usage is toggled via env so
# the chart can change behavior without rebuilding the image.
# ---------------------------------------------------------------------------
import ctypes.util
import json
import os
import platform

import dj_database_url

from temba.settings_common import *  # noqa


def _env(key, default=None):
    return os.environ.get(key, default)


def _bool(key, default=False):
    v = os.environ.get(key)
    return default if v is None else v.strip().lower() in ("1", "true", "on", "yes")


def _list(key, default="", sep=";"):
    raw = os.environ.get(key, default)
    return [x for x in (p.strip() for p in raw.split(sep)) if x]


# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------
ROOT_URLCONF = _env("ROOT_URLCONF", "temba.urls")
DEBUG = _bool("DJANGO_DEBUG", False)
SECRET_KEY = _env("SECRET_KEY")
if not SECRET_KEY:
    raise RuntimeError("SECRET_KEY environment variable is required")

HOSTNAME = _env("DOMAIN_NAME", "rapidpro.localhost")
TEMBA_HOST = _env("TEMBA_HOST", HOSTNAME)
ALLOWED_HOSTS = _list("ALLOWED_HOSTS", HOSTNAME) or [HOSTNAME]
INTERNAL_IPS = ("*",)

# Django 4.2 CSRF needs scheme-qualified trusted origins behind an HTTPS ingress.
if os.environ.get("CSRF_TRUSTED_ORIGINS"):
    CSRF_TRUSTED_ORIGINS = _list("CSRF_TRUSTED_ORIGINS")
else:
    CSRF_TRUSTED_ORIGINS = [
        o for h in ALLOWED_HOSTS if h not in ("*",) for o in (f"https://{h}", f"http://{h}")
    ]
SECURE_PROXY_SSL_HEADER = (_env("SECURE_PROXY_SSL_HEADER", "HTTP_X_FORWARDED_PROTO"), "https")
IS_PROD = _bool("IS_PROD", False)

LOGGING["root"]["level"] = _env("DJANGO_LOG_LEVEL", "INFO")  # noqa: F405

# ---------------------------------------------------------------------------
# Databases (PostGIS engine; optional read replica via DATABASE_URL_READONLY)
# ---------------------------------------------------------------------------
DATABASE_URL = _env("DATABASE_URL")
if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL environment variable is required")

_default_db = dj_database_url.parse(DATABASE_URL)
_default_db["ENGINE"] = "django.contrib.gis.db.backends.postgis"
_default_db["CONN_MAX_AGE"] = int(_env("DATABASE_CONN_MAX_AGE", "60"))
_default_db["ATOMIC_REQUESTS"] = True
_default_db["DISABLE_SERVER_SIDE_CURSORS"] = True

_readonly_url = _env("DATABASE_URL_READONLY")
if _readonly_url:
    _readonly_db = dj_database_url.parse(_readonly_url)
    _readonly_db["ENGINE"] = "django.contrib.gis.db.backends.postgis"
    _readonly_db["CONN_MAX_AGE"] = int(_env("DATABASE_CONN_MAX_AGE", "60"))
    _readonly_db["DISABLE_SERVER_SIDE_CURSORS"] = True
else:
    _readonly_db = _default_db.copy()

DATABASES = {"default": _default_db, "readonly": _readonly_db}

# ---------------------------------------------------------------------------
# Redis / cache / Celery (broker engine is redis OR valkey; same wire protocol)
# ---------------------------------------------------------------------------
REDIS_URL = _env("REDIS_URL")
if not REDIS_URL:
    raise RuntimeError("REDIS_URL environment variable is required")

CACHES = {
    "default": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": _env("CACHE_URL", REDIS_URL),
        "OPTIONS": {"CLIENT_CLASS": "django_redis.client.DefaultClient"},
    }
}

CELERY_BROKER_URL = _env("BROKER_URL", REDIS_URL)
if os.environ.get("CELERY_RESULT_BACKEND"):
    CELERY_RESULT_BACKEND = _env("CELERY_RESULT_BACKEND")

# Queue isolation: keep heavy exports off the default queue so light/priority
# tasks are never blocked behind a long export. Extendable via env without a
# rebuild (CELERY_TASK_ROUTES as a JSON object of {task_name: {queue: ...}}).
CELERY_TASK_DEFAULT_QUEUE = "celery"
CELERY_TASK_ROUTES = {
    "temba.msgs.tasks.export_messages_task": {"queue": "exports"},
    "temba.contacts.tasks.export_contacts_task": {"queue": "exports"},
    "temba.flows.tasks.export_flow_results_task": {"queue": "exports"},
}
try:
    CELERY_TASK_ROUTES.update(json.loads(os.environ.get("CELERY_TASK_ROUTES", "{}")))
except (ValueError, TypeError):
    pass

# Elasticsearch (v9 uses ELASTIC_ENDPOINT_URL; honor the chart's ELASTICSEARCH_URL).
_es_url = _env("ELASTICSEARCH_URL") or _env("ELASTIC_ENDPOINT_URL")
if _es_url:
    ELASTIC_ENDPOINT_URL = _es_url

# ---------------------------------------------------------------------------
# GeoDjango libraries (arch-auto-discovery; works on amd64 and arm64/Graviton)
# ---------------------------------------------------------------------------
_gdal = _env("GDAL_LIBRARY_PATH") or ctypes.util.find_library("gdal")
_geos = _env("GEOS_LIBRARY_PATH") or ctypes.util.find_library("geos_c")
_proj = _env("PROJ_LIBRARY_PATH") or ctypes.util.find_library("proj")
if _gdal:
    GDAL_LIBRARY_PATH = _gdal
if _geos:
    GEOS_LIBRARY_PATH = _geos
if _proj:
    PROJ_LIBRARY_PATH = _proj

# ---------------------------------------------------------------------------
# Storage (Django 4.2 STORAGES API). Static stays local (WhiteNoise, baked);
# media/exports/archives go to S3 when a bucket is configured.
# ---------------------------------------------------------------------------
AWS_ACCESS_KEY_ID = _env("AWS_ACCESS_KEY_ID", "")
AWS_SECRET_ACCESS_KEY = _env("AWS_SECRET_ACCESS_KEY", "")
AWS_STORAGE_BUCKET_NAME = _env("AWS_STORAGE_BUCKET_NAME", "")
AWS_S3_REGION_NAME = _env("AWS_S3_REGION_NAME", "") or None
AWS_S3_ENDPOINT_URL = _env("AWS_S3_ENDPOINT_URL") or None
AWS_S3_ADDRESSING_STYLE = _env("AWS_S3_ADDRESSING_STYLE", "auto")
AWS_DEFAULT_ACL = _env("AWS_DEFAULT_ACL") or None
AWS_QUERYSTRING_AUTH = _bool("AWS_QUERYSTRING_AUTH", True)

if AWS_STORAGE_BUCKET_NAME:
    _s3 = "storages.backends.s3boto3.S3Boto3Storage"
    _archive_bucket = _env("ARCHIVE_BUCKET", AWS_STORAGE_BUCKET_NAME)
    # default = exports/imports (must be shared across replicas, hence S3),
    # public = media uploads, archives = where rp-archiver writes.
    STORAGES["default"] = {"BACKEND": _s3, "OPTIONS": {"bucket_name": AWS_STORAGE_BUCKET_NAME}}  # noqa: F405
    STORAGES["public"] = {  # noqa: F405
        "BACKEND": _s3,
        "OPTIONS": {"bucket_name": AWS_STORAGE_BUCKET_NAME, "default_acl": "public-read", "querystring_auth": False},
    }
    STORAGES["archives"] = {"BACKEND": _s3, "OPTIONS": {"bucket_name": _archive_bucket}}  # noqa: F405

# RapidPro's system check requires an absolute media base URL.
STORAGE_URL = _env("STORAGE_URL", "")
if not STORAGE_URL:
    if AWS_STORAGE_BUCKET_NAME and AWS_S3_ENDPOINT_URL:
        STORAGE_URL = "%s/%s" % (AWS_S3_ENDPOINT_URL.rstrip("/"), AWS_STORAGE_BUCKET_NAME)
    elif AWS_STORAGE_BUCKET_NAME:
        STORAGE_URL = "https://%s.s3.%s.amazonaws.com" % (AWS_STORAGE_BUCKET_NAME, AWS_S3_REGION_NAME or "us-east-1")
    else:
        STORAGE_URL = "https://%s" % HOSTNAME

# Serve baked static via WhiteNoise (added to the image; not an upstream dep).
if "whitenoise.middleware.WhiteNoiseMiddleware" not in MIDDLEWARE:  # noqa: F405
    _mw = list(MIDDLEWARE)  # noqa: F405
    try:
        _idx = _mw.index("django.middleware.security.SecurityMiddleware") + 1
    except ValueError:
        _idx = 0
    _mw.insert(_idx, "whitenoise.middleware.WhiteNoiseMiddleware")
    MIDDLEWARE = tuple(_mw)

# ---------------------------------------------------------------------------
# Offline asset compression (baked at build; runtime just reads the manifest)
# ---------------------------------------------------------------------------
COMPRESS_ENABLED = _bool("DJANGO_COMPRESSOR", True)
COMPRESS_OFFLINE = True
COMPRESS_OFFLINE_MANIFEST = "manifest-%s.json" % _env("RAPIDPRO_VERSION", "dev")

# ---------------------------------------------------------------------------
# Branding (v9 single BRAND dict). Merge env overrides onto the upstream
# default so all keys the templates expect (e.g. "description") survive, while
# host/domain/email are pinned to this deployment.
# ---------------------------------------------------------------------------
BRAND["name"] = _env("BRAND_NAME", BRAND["name"])  # noqa: F405
BRAND["hosts"] = _list("BRAND_HOSTS", "") or [HOSTNAME]
BRAND["domain"] = _env("BRAND_DOMAIN", HOSTNAME)
BRAND["ticket_domain"] = _env("BRAND_TICKET_DOMAIN", HOSTNAME)
BRAND["docs_link"] = _env("BRAND_DOCS_LINK", BRAND.get("docs_link", "http://docs.rapidpro.io"))  # noqa: F405
if isinstance(BRAND.get("emails"), dict):  # noqa: F405
    BRAND["emails"]["notifications"] = _env("BRAND_EMAIL", BRAND["emails"].get("notifications"))  # noqa: F405
if isinstance(BRAND.get("logos"), dict):  # noqa: F405
    BRAND["logos"]["primary"] = _env("BRAND_LOGO", BRAND["logos"].get("primary"))  # noqa: F405
    BRAND["logos"]["favico"] = _env("BRAND_FAVICO", BRAND["logos"].get("favico"))  # noqa: F405
if os.environ.get("BRAND_FEATURES"):
    BRAND["features"] = _list("BRAND_FEATURES", "", sep=",")

# ---------------------------------------------------------------------------
# Mailroom / email / send flags / API throttles
# ---------------------------------------------------------------------------
MAILROOM_URL = _env("MAILROOM_URL", "") or None
MAILROOM_AUTH_TOKEN = _env("MAILROOM_AUTH_TOKEN", "") or None

SEND_MESSAGES = _bool("SEND_MESSAGES", False)
SEND_WEBHOOKS = _bool("SEND_WEBHOOKS", False)
SEND_EMAILS = _bool("SEND_EMAILS", False)
SEND_AIRTIME = _bool("SEND_AIRTIME", False)
SEND_CALLS = _bool("SEND_CALLS", False)

EMAIL_HOST = _env("EMAIL_HOST", "smtp.gmail.com")
EMAIL_HOST_USER = _env("EMAIL_HOST_USER", "server@temba.io")
EMAIL_HOST_PASSWORD = _env("EMAIL_HOST_PASSWORD", "")
EMAIL_PORT = int(_env("EMAIL_PORT", "25"))
EMAIL_USE_TLS = _bool("EMAIL_USE_TLS", True)
DEFAULT_FROM_EMAIL = _env("DEFAULT_FROM_EMAIL", "server@temba.io")
FLOW_FROM_EMAIL = _env("FLOW_FROM_EMAIL", DEFAULT_FROM_EMAIL)

for _k in ("v2", "v2.contacts", "v2.messages", "v2.runs", "v2.broadcasts"):
    _envk = "API_THROTTLE_" + _k.upper().replace(".", "_")
    if os.environ.get(_envk):
        REST_FRAMEWORK["DEFAULT_THROTTLE_RATES"][_k] = os.environ[_envk]  # noqa: F405

# Optional v9 Facebook/WhatsApp embedded-signup config IDs.
for _fb in ("FACEBOOK_LOGIN_WHATSAPP_CONFIG_ID", "FACEBOOK_LOGIN_MESSENGER_CONFIG_ID", "FACEBOOK_LOGIN_INSTAGRAM_CONFIG_ID"):
    if os.environ.get(_fb):
        globals()[_fb] = os.environ[_fb]
