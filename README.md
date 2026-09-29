# Harbor adapter for proxying Ballerina Central packages and metadata

## Harbor API

This adapter exposes Harbor-compatible OCI registry endpoints so Harbor can treat Ballerina Central packages as registry artifacts.

### `GET /v2/{org}/{pkg}/manifests/latest`

Purpose: Returns the manifest for the latest available version set of a package.

How it works: When Harbor asks for `latest`, the adapter queries Ballerina Central for the package's version list, serializes that list into JSON, hashes the JSON to create a content-addressable digest, and returns an OCI manifest that points to that version-list blob.

What Harbor gets: A standard OCI manifest with a digest that Harbor can use to fetch the actual version index through the blob endpoint.

### `HEAD /v2/{org}/{pkg}/manifests/latest`

Purpose: Returns only the manifest headers for the latest package view.

How it works: The adapter uses cached version metadata when available so Harbor can verify the digest and ETag without downloading the full manifest body again.

What Harbor gets: The same digest identity information as `GET`, but with no payload body.

### `GET /v2/{org}/{pkg}/manifests/{version}`

Purpose: Returns the manifest for one specific Ballerina package version.

How it works: The adapter resolves version metadata from Ballerina Central, extracts the Bala download URL and advertised digest, and builds an OCI manifest that represents that exact version.

What Harbor gets: A version-specific OCI manifest that tells Harbor which blob digest corresponds to the package payload.

### `HEAD /v2/{org}/{pkg}/manifests/{version}`

Purpose: Returns only the headers for a specific package version manifest.

How it works: The adapter first checks its metadata cache, then falls back to Central if needed, so Harbor can quickly confirm the manifest digest and ETag.

What Harbor gets: A registry-style response that confirms the version manifest identity without transferring the manifest body.

### `GET /v2/{org}/{pkg}/blobs/{digest}`

Purpose: Returns the actual bytes referenced by a manifest digest.

How it works: If the digest belongs to the version index, the adapter returns the JSON version list. If the digest belongs to a package version, the adapter resolves a fresh, presigned Bala URL from Central and redirects (`307`) to it, so Harbor downloads the `.bala` straight from Central's CDN, the way registries backed by object storage redirect their blobs. The adapter never relays or buffers bala bytes itself.

What Harbor gets: The content-addressable payload that the manifest advertised, which Harbor can store, cache, and serve as an OCI blob.

### `HEAD /v2/{org}/{pkg}/blobs/{digest}`

Purpose: Confirms that a blob digest is available.

How it works: The adapter responds with the digest and blob headers expected by Harbor so it can validate the object before issuing a full GET.

What Harbor gets: A lightweight existence check for the content-addressed blob.

## How Harbor and the Adapter Work Together

1. Harbor requests a manifest for `latest` or a specific version.
2. The adapter translates that request into Ballerina Central metadata calls.
3. The adapter returns an OCI manifest containing the digest of the version index or Bala payload.
4. Harbor follows the digest and calls the blob endpoint.
5. The adapter serves the actual bytes, either from cache or by fetching them from Central.

This flow lets Harbor act as the registry layer while Ballerina Central remains the package source of truth.


## Configuration

All settings are `configurable` (see `config.bal`); the defaults below apply when `Config.toml` omits them.

```toml
port = 8080

centralUrl = "https://api.central.ballerina.io"
centralTimeout = 30                 # seconds
centralMaxActiveConnections = 100
centralMaxIdleConnections = 20
centralPoolWaitTime = 30            # seconds

balaCdnTimeout = 30                 # seconds, HEAD to the bala CDN for sizes

# Each cache: capacity (entries), maxAge and cleanupInterval (seconds), optional evictionFactor (default 0.2)
[blobCacheSettings]
capacity = 200
maxAge = 600
cleanupInterval = 60

[blobSourcesSettings]
capacity = 500
maxAge = 600
cleanupInterval = 60

[versionMetaCacheSettings]
capacity = 1000
maxAge = 1800
cleanupInterval = 120

[versionsListCacheSettings]
capacity = 500
maxAge = 300
cleanupInterval = 60

[depGraphMetaCacheSettings]
capacity = 1000
maxAge = 1800
cleanupInterval = 120

[manifestsByDigestSettings]
capacity = 1000
maxAge = 1800
cleanupInterval = 120

[subjectManifestSourcesSettings]
capacity = 1000
maxAge = 1800
cleanupInterval = 120
```

A cache table must set `capacity`, `maxAge` and `cleanupInterval` together if it is overridden.

## Production Logging

Request-level details (`Received ...`, cache hits, manifest builds) are logged at `DEBUG`. At `INFO`, the adapter logs only warnings and failures, and per-request lines come from the HTTP access log. Upstream failures return a generic `502` to the client; the cause is logged.

`Config.toml` is git-ignored, so supply it at deploy time:

```toml
[ballerina.log]
level = "INFO"        # DEBUG for troubleshooting
format = "json"

[ballerina.http.accessLogConfig]
console = true        # method, path, status, latency per request

[ballerina.observe]
tracingEnabled = true
tracingProvider = "jaeger"   # also requires `import ballerinax/jaeger as _;`
```

With tracing enabled, every log line carries `traceId`/`spanId`, which correlates the lines of one request.
