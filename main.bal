import ballerina/cache;
import ballerina/http;
import ballerina/log;

final http:Client centralClient = check new ("https://api.central.ballerina.io", {
    timeout: 30,
    poolConfig: {
        maxActiveConnections: 100,
        maxIdleConnections: 20,
        waitTime: 30
    }
});

final string OCI_EMPTY_CONFIG_DIGEST = "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";

// Blob cache: digest -> bytes, TTL 10 min, max 200 entries
final cache:Cache blobCache = new (capacity = 200, evictionFactor = 0.2, defaultMaxAge = 600, cleanupInterval = 60);
// Blob source lookup: digest -> "org/name" or "org/name/version", TTL 10 min
final cache:Cache blobSources = new (capacity = 500, evictionFactor = 0.2, defaultMaxAge = 600, cleanupInterval = 60);
// Version metadata cache: "org/name/version" -> "digest|balaURL", TTL 30 min
final cache:Cache versionMetaCache = new (capacity = 1000, evictionFactor = 0.2, defaultMaxAge = 1800, cleanupInterval = 120);
// Versions list cache: "org/name" -> JSON string of versions array, TTL 5 min
final cache:Cache versionsListCache = new (capacity = 500, evictionFactor = 0.2, defaultMaxAge = 300, cleanupInterval = 60);
// Dependency graph referrer metadata: subject (version manifest) digest -> ReferrerInfo, TTL 30 min.
// A cache hit here means Central's resolve-dependencies call is skipped entirely.
final cache:Cache depGraphMetaCache = new (capacity = 1000, evictionFactor = 0.2, defaultMaxAge = 1800, cleanupInterval = 120);
// Referrer manifest bytes: referrer manifest digest -> manifest JSON text, TTL 30 min
final cache:Cache referrerManifestCache = new (capacity = 1000, evictionFactor = 0.2, defaultMaxAge = 1800, cleanupInterval = 120);
// Version manifest self-digest -> SubjectManifestInfo{org/name/version, manifest size}. Populated
// whenever a version manifest is built, since a referrers query only ever carries that digest and
// there is no other way to recover which package it belongs to. Same TTL as versionMetaCache so
// the two rise and fall together (see the HEAD-manifest/blobSources TTL note on that cache).
final cache:Cache subjectManifestSources = new (capacity = 1000, evictionFactor = 0.2, defaultMaxAge = 1800, cleanupInterval = 120);

service / on new http:Listener(8080) {
    // GET /v2
    resource function get v2() returns http:Response {
        log:printInfo("Received request for /v2/");
        http:Response v2Response = new;
        v2Response.statusCode = 200;
        v2Response.setHeader("Docker-Distribution-API-Version", "2.0");
        return v2Response;
    }

    // HEAD /v2
    resource function head v2() returns http:Response {
        http:Response v2Response = new;
        v2Response.statusCode = 200;
        v2Response.setHeader("Docker-Distribution-API-Version", "2.0");
        return v2Response;
    }

    // GET /v2/{org}/{name}/manifests/latest
    resource function get v2/[string org]/[string name]/manifests/latest() returns http:Response|error {
        log:printInfo("Received GET latest manifest request", org = org, name = name);
        return buildLatestManifestResponse(org, name);
    }

    // HEAD /v2/{org}/{name}/manifests/latest
    resource function head v2/[string org]/[string name]/manifests/latest() returns http:Response|error {
        log:printInfo("Received HEAD latest manifest request", org = org, name = name);
        // Use cached versions JSON to compute digest without a full manifest build
        string listKey = string `${org}/${name}`;
        string digest = "";
        if versionsListCache.hasKey(listKey) {
            any|cache:Error cacheEntry = versionsListCache.get(listKey);
            if cacheEntry is string {
                digest = computeSha256Digest(cacheEntry.toBytes());
            }
        }
        if digest == "" {
            // Cache miss — do a full build to populate caches and get the digest
            http:Response|error manifestResponse = buildLatestManifestResponse(org, name);
            if manifestResponse is error {
                return manifestResponse;
            }
            string|http:HeaderNotFoundError digestHeader = manifestResponse.getHeader("Docker-Content-Digest");
            digest = digestHeader is string ? digestHeader : "";
        }
        http:Response headResponse = new;
        headResponse.statusCode = 200;
        headResponse.setHeader("Content-Type", "application/vnd.oci.image.manifest.v1+json");
        headResponse.setHeader("Docker-Content-Digest", digest);
        headResponse.setHeader("ETag", "\"" + digest + "\"");
        return headResponse;
    }

    // GET /v2/{org}/{name}/{platform}/manifests/{version} — test endpoint
    resource function get v2/[string org]/[string name]/[string platform]/manifests/[string version]() returns http:Response {
        log:printInfo("Received 3-segment manifest request", org = org, name = name, platform = platform, version = version);
        http:Response testResponse = new;
        testResponse.statusCode = 200;
        testResponse.setTextPayload("ok");
        return testResponse;
    }
    resource function head v2/[string org]/[string name]/[string platform]/manifests/[string version]() returns http:Response {
        log:printInfo("Received 3-segment manifest request", org = org, name = name, platform = platform, version = version);
        http:Response testResponse = new;
        testResponse.statusCode = 200;
        testResponse.setTextPayload("ok");
        return testResponse;
    }

    // GET /v2/{org}/{name}/manifests/{version}
    resource function get v2/[string org]/[string name]/manifests/[string version](http:Request req) returns http:Response|error {
        string[] headerNames = req.getHeaderNames();
        foreach string headerName in headerNames {
            string|http:HeaderNotFoundError headerValue = req.getHeader(headerName);
            if headerValue is string {
                log:printInfo("Request header", name = headerName, value = headerValue);
            }
        }
        // A referrer manifest (e.g. the dependency-graph artifact) is requested by its own
        // digest, not a version tag — serve it straight from cache if that's what this is.
        if referrerManifestCache.hasKey(version) {
            any|cache:Error cachedManifest = referrerManifestCache.get(version);
            if cachedManifest is string {
                log:printInfo("Serving cached referrer manifest", digest = version);
                return buildCachedManifestResponse(version, cachedManifest);
            }
        }

        log:printInfo("Received GET manifest request", org = org, name = name, version = version);
        return buildVersionManifestResponse(org, name, version);
    }

    // HEAD /v2/{org}/{name}/manifests/{version}
    resource function head v2/[string org]/[string name]/manifests/[string version]() returns http:Response|error {
        log:printInfo("Received HEAD manifest request", org = org, name = name, version = version);

        if referrerManifestCache.hasKey(version) {
            any|cache:Error cachedManifest = referrerManifestCache.get(version);
            if cachedManifest is string {
                return buildCachedManifestResponse(version, cachedManifest);
            }
        }

        // Check metadata cache first to avoid a live Central call
        string metaKey = string `${org}/${name}/${version}`;
        string digest = "";
        if versionMetaCache.hasKey(metaKey) {
            any|cache:Error metaEntry = versionMetaCache.get(metaKey);
            if metaEntry is string {
                int? sepIdxOpt = metaEntry.indexOf("|");
                int sepIdx = sepIdxOpt is int ? sepIdxOpt : -1;
                if sepIdx > 0 {
                    digest = metaEntry.substring(0, sepIdx);
                }
            }
        }
        if digest == "" {
            string|http:Response|error digestResult = fetchVersionDigestFromCentral(org, name, version);
            if digestResult is http:Response {
                return digestResult;
            }
            if digestResult is error {
                log:printError("Failed fetching version digest", 'error = digestResult, org = org, name = name, version = version);
                http:Response errResponse = new;
                errResponse.statusCode = 502;
                errResponse.setTextPayload("Failed to fetch version digest: " + digestResult.message());
                return errResponse;
            }
            digest = digestResult;
        }
        http:Response headResponse = new;
        headResponse.statusCode = 200;
        headResponse.setHeader("Content-Type", "application/vnd.oci.image.manifest.v1+json");
        headResponse.setHeader("Docker-Content-Digest", digest);
        headResponse.setHeader("ETag", "\"" + digest + "\"");
        return headResponse;
    }

    // GET /v2/{org}/{name}/referrers/{digest} — OCI Distribution Spec referrers API.
    // `digest` is a version manifest's own (self) digest, discovered by the caller from a prior
    // manifest GET/HEAD. Currently the only referrer type this adapter publishes is the
    // dependency graph, fetched from Central's resolve-dependencies endpoint (never the bala).
    resource function get v2/[string org]/[string name]/referrers/[string digest](http:Request req)
            returns http:Response|error {
        log:printInfo("Received GET referrers request", org = org, name = name, digest = digest);
        string? artifactTypeFilter = req.getQueryParamValue("artifactType");

        if !subjectManifestSources.hasKey(digest) {
            // Unknown subject digest — an empty index is the spec-correct response, not a 404.
            return buildReferrersIndexResponse([]);
        }
        any|cache:Error subjectEntry = subjectManifestSources.get(digest);
        if !(subjectEntry is SubjectManifestInfo) {
            return buildReferrersIndexResponse([]);
        }

        if artifactTypeFilter is string && artifactTypeFilter != DEP_GRAPH_ARTIFACT_TYPE {
            return buildReferrersIndexResponse([]);
        }

        string[] parts = re `/`.split(subjectEntry.metaKey);
        if parts.length() != 3 {
            log:printWarn("Malformed subject source key", metaKey = subjectEntry.metaKey);
            return buildReferrersIndexResponse([]);
        }

        ReferrerInfo|http:Response|error referrerResult = buildDependencyGraphReferrer(
                parts[0], parts[1], parts[2], digest, subjectEntry.size);
        if referrerResult is http:Response {
            return referrerResult;
        }
        if referrerResult is error {
            log:printWarn("Failed to build dependency graph referrer", 'error = referrerResult,
                    org = parts[0], name = parts[1], version = parts[2]);
            return buildReferrersIndexResponse([]);
        }
        return buildReferrersIndexResponse([referrerResult]);
    }

    // HEAD /v2/{org}/{name}/blobs/{digest}
    resource function head v2/[string org]/[string name]/blobs/[string digest]() returns http:Response {
        log:printInfo("Received HEAD request for blob", org = org, name = name, digest = digest);
        // All digests we issue are valid — always acknowledge existence
        http:Response headResponse = new;
        headResponse.statusCode = 200;
        headResponse.setHeader("Content-Type", "application/octet-stream");
        headResponse.setHeader("Docker-Content-Digest", digest);
        return headResponse;
    }

    // GET /v2/{org}/{name}/blobs/{digest}
    resource function get v2/[string org]/[string name]/blobs/[string digest]() returns http:Response|error {
        log:printInfo("Received request for blob", org = org, name = name, digest = digest);

        if digest == OCI_EMPTY_CONFIG_DIGEST {
            http:Response configResponse = new;
            configResponse.statusCode = 200;
            configResponse.setTextPayload("{}", contentType = "application/vnd.oci.image.config.v1+json");
            return configResponse;
        }

        // Return from cache if already fetched
        if blobCache.hasKey(digest) {
            any|cache:Error cacheEntry = blobCache.get(digest);
            if cacheEntry is byte[] {
                log:printInfo("Serving blob from cache", digest = digest);
                return buildBlobResponse(cacheEntry.clone(), digest, "application/octet-stream");
            }
        }

        string? sourceKey = ();
        if blobSources.hasKey(digest) {
            any|cache:Error sourceEntry = blobSources.get(digest);
            if sourceEntry is string {
                sourceKey = sourceEntry;
            }
        }
        log:printInfo("Source key for digest", sourceKey = sourceKey);
        if sourceKey is () {
            log:printError("Unknown blob digest", digest = digest);
            http:Response notFound = new;
            notFound.statusCode = 404;
            notFound.setTextPayload("{\"errors\":[{\"code\":\"BLOB_UNKNOWN\"}]}", contentType = "application/json");
            return notFound;
        }

        string[] parts = re `/`.split(sourceKey);

        if parts.length() == 2 {
            // "org/name" — serve versions JSON
            string decodedOrg = parts[0];
            string decodedName = parts[1];
            log:printInfo("Serving versions blob", org = decodedOrg, name = decodedName);

            string[]|http:Response|error versionsResult = fetchVersionsFromCentral(decodedOrg, decodedName);
            if versionsResult is http:Response {
                return versionsResult;
            }
            if versionsResult is error {
                log:printError("Failed fetching versions", 'error = versionsResult);
                http:Response errResponse = new;
                errResponse.statusCode = 502;
                errResponse.setTextPayload("Failed to fetch versions: " + versionsResult.message());
                return errResponse;
            }

            byte[] versionsBytes = versionsResult.toJsonString().toBytes();
            // Use the digest Harbor requested — it was advertised in the manifest
            cache:Error? cacheErr = blobCache.put(digest, versionsBytes, -1);
            if cacheErr is cache:Error {
                log:printWarn("Failed to cache versions blob", digest = digest, 'error = cacheErr);
            }
            log:printInfo("Serving versions blob", digest = digest, size = versionsBytes.length());
            return buildBlobResponse(versionsBytes, digest, "application/octet-stream");

        } else if parts.length() == 3 {
            // "org/name/version" — serve bala bytes
            string decodedOrg = parts[0];
            string decodedName = parts[1];
            string decodedVersion = parts[2];
            log:printInfo("Serving bala blob", org = decodedOrg, name = decodedName, version = decodedVersion);

            // Use cached balaURL if available (set by buildVersionManifestResponse)
            string balaURL = "";
            string urlKey = string `url:${digest}`;
            if blobSources.hasKey(urlKey) {
                any|cache:Error urlEntry = blobSources.get(urlKey);
                if urlEntry is string {
                    balaURL = urlEntry;
                    log:printInfo("Using cached balaURL", digest = digest);
                }
            }
            if balaURL == "" {
                // Fall back to re-fetching metadata from Central
                VersionMetadata|http:Response|error metadataResult =
                        resolveBalaURL(decodedOrg, decodedName, decodedVersion);
                if metadataResult is http:Response {
                    return metadataResult;
                }
                if metadataResult is error {
                    log:printError("Failed resolving balaURL", 'error = metadataResult);
                    http:Response errResponse = new;
                    errResponse.statusCode = 502;
                    errResponse.setTextPayload("Failed to resolve bala URL: " + metadataResult.message());
                    return errResponse;
                }
                balaURL = metadataResult.balaURL;
            }

            byte[]|error balaBytes = downloadBalaBytes(balaURL);
            if balaBytes is error {
                log:printError("Failed downloading bala", 'error = balaBytes);
                http:Response errResponse = new;
                errResponse.statusCode = 502;
                errResponse.setTextPayload("Failed to download bala: " + balaBytes.message());
                return errResponse;
            }

            // Use the digest Harbor requested — it was advertised in the manifest
            cache:Error? cacheErr = blobCache.put(digest, balaBytes, -1);
            if cacheErr is cache:Error {
                log:printWarn("Failed to cache bala blob", digest = digest, 'error = cacheErr);
            }
            log:printInfo("Serving bala blob", digest = digest, size = balaBytes.length());
            return buildBlobResponse(balaBytes, digest, "application/octet-stream");

        } else {
            log:printError("Unexpected blob source format", sourceKey = sourceKey);
            http:Response notFound = new;
            notFound.statusCode = 404;
            notFound.setTextPayload("{\"errors\":[{\"code\":\"BLOB_UNKNOWN\"}]}", contentType = "application/json");
            return notFound;
        }
    }
}