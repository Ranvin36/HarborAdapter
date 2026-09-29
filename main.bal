import ballerina/cache;
import ballerina/http;
import ballerina/log;

final http:Client centralClient = check new (centralUrl, {
    timeout: centralTimeout,
    poolConfig: {
        maxActiveConnections: centralMaxActiveConnections,
        maxIdleConnections: centralMaxIdleConnections,
        waitTime: centralPoolWaitTime
    }
});

final string OCI_EMPTY_CONFIG_DIGEST = "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";

// digest -> byte[]
final cache:Cache blobCache = newCache(blobCacheSettings);
// digest -> IndexSource | "org/name/version"
final cache:Cache blobSources = newCache(blobSourcesSettings);
// "org/name/version" -> VersionManifest
final cache:Cache versionMetaCache = newCache(versionMetaCacheSettings);
// "org/name@distribution" -> versions JSON string
final cache:Cache versionsListCache = newCache(versionsListCacheSettings);
// subject manifest digest -> ReferrerInfo
final cache:Cache depGraphMetaCache = newCache(depGraphMetaCacheSettings);
// manifest digest -> manifest JSON text
final cache:Cache manifestsByDigest = newCache(manifestsByDigestSettings);
// version manifest digest -> SubjectManifestInfo
final cache:Cache subjectManifestSources = newCache(subjectManifestSourcesSettings);

service / on new http:Listener(port) {
    // GET /v2
    resource function get v2() returns http:Response {
        log:printDebug("Received request for /v2/");
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
        log:printDebug("Received GET latest manifest request", org = org, name = name);
        return buildIndexManifestResponse(org, name);
    }

    // HEAD /v2/{org}/{name}/manifests/latest
    resource function head v2/[string org]/[string name]/manifests/latest() returns http:Response|error {
        log:printDebug("Received HEAD latest manifest request", org = org, name = name);
        http:Response|error latestResponse = buildIndexManifestResponse(org, name);
        if latestResponse is error {
            return latestResponse;
        }
        return toHeadResponse(latestResponse);
    }

    // GET /v2/{org}/{name}/{platform}/manifests/{version} — test endpoint
    resource function get v2/[string org]/[string name]/[string platform]/manifests/[string version]() returns http:Response {
        log:printDebug("Received 3-segment manifest request", org = org, name = name, platform = platform, version = version);
        http:Response testResponse = new;
        testResponse.statusCode = 200;
        testResponse.setTextPayload("ok");
        return testResponse;
    }
    resource function head v2/[string org]/[string name]/[string platform]/manifests/[string version]() returns http:Response {
        log:printDebug("Received 3-segment manifest request", org = org, name = name, platform = platform, version = version);
        http:Response testResponse = new;
        testResponse.statusCode = 200;
        testResponse.setTextPayload("ok");
        return testResponse;
    }

    resource function get v2/[string org]/[string name]/manifests/[string version]() returns http:Response|error {
        http:Response? byDigest = getManifestByDigest(version);
        if byDigest is http:Response {
            log:printDebug("Serving manifest by digest", digest = version);
            return byDigest;
        }
        if version.startsWith("sha256:") {
            return buildRegistryErrorResponse(404, "MANIFEST_UNKNOWN", "manifest unknown to registry");
        }
        string? distribution = indexTagToDistribution(version);
        if distribution is string {
            log:printDebug("Received GET index manifest request", org = org, name = name, distribution = distribution);
            return buildIndexManifestResponse(org, name, distribution);
        }
        log:printDebug("Received GET manifest request", org = org, name = name, version = version);
        return buildVersionManifestResponse(org, name, version);
    }

    // HEAD /v2/{org}/{name}/manifests/{version}
    resource function head v2/[string org]/[string name]/manifests/[string version]() returns http:Response|error {
        log:printDebug("Received HEAD manifest request", org = org, name = name, version = version);
        http:Response? byDigest = getManifestByDigest(version);
        if byDigest is http:Response {
            return toHeadResponse(byDigest);
        }
        if version.startsWith("sha256:") {
            return buildRegistryErrorResponse(404, "MANIFEST_UNKNOWN", "manifest unknown to registry");
        }
        string? distribution = indexTagToDistribution(version);
        if distribution is string {
            http:Response|error indexResponse = buildIndexManifestResponse(org, name, distribution);
            if indexResponse is error {
                return indexResponse;
            }
            return toHeadResponse(indexResponse);
        }
        return toHeadResponse(buildVersionManifestResponse(org, name, version));
    }

    resource function get v2/[string org]/[string name]/referrers/[string digest](http:Request req)
            returns http:Response|error {
        log:printDebug("Received GET referrers request", org = org, name = name, digest = digest);
        string? artifactTypeFilter = req.getQueryParamValue("artifactType");

        if !subjectManifestSources.hasKey(digest) {
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
        if referrerResult is error {
            log:printWarn("Failed to build dependency graph referrer", 'error = referrerResult,
                    org = parts[0], name = parts[1], version = parts[2]);
            return buildReferrersIndexResponse([]);
        }
        if referrerResult is http:Response {
            log:printWarn("Upstream error building dependency graph referrer",
                    org = parts[0], name = parts[1], version = parts[2], status = referrerResult.statusCode);
            return buildReferrersIndexResponse([]);
        }
        return buildReferrersIndexResponse([referrerResult]);
    }

    resource function head v2/[string org]/[string name]/blobs/[string digest]() returns http:Response|error {
        log:printDebug("Received HEAD request for blob", org = org, name = name, digest = digest);

        if digest == OCI_EMPTY_CONFIG_DIGEST {
            http:Response headResponse = new;
            headResponse.statusCode = 200;
            headResponse.setHeader("Content-Type", "application/vnd.oci.image.config.v1+json");
            headResponse.setHeader("Docker-Content-Digest", digest);
            headResponse.setHeader("Content-Length", "2");
            return headResponse;
        }

        if blobCache.hasKey(digest) {
            any|cache:Error cacheEntry = blobCache.get(digest);
            if cacheEntry is byte[] {
                http:Response headResponse = new;
                headResponse.statusCode = 200;
                headResponse.setHeader("Content-Type", "application/octet-stream");
                headResponse.setHeader("Docker-Content-Digest", digest);
                headResponse.setHeader("Content-Length", cacheEntry.length().toString());
                return headResponse;
            }
        }

        if blobSources.hasKey(digest) {
            any|cache:Error sourceEntry = blobSources.get(digest);
            if sourceEntry is IndexSource {
                // Size unknown without re-fetching; return 200 without Content-Length.
                http:Response headResponse = new;
                headResponse.statusCode = 200;
                headResponse.setHeader("Content-Type", "application/octet-stream");
                headResponse.setHeader("Docker-Content-Digest", digest);
                return headResponse;
            }
            if sourceEntry is string {
                // "org/name/version" — look up the cached manifest for the layer size.
                any|cache:Error manifestEntry = versionMetaCache.get(sourceEntry);
                if manifestEntry is VersionManifest {
                    http:Response headResponse = new;
                    headResponse.statusCode = 200;
                    headResponse.setHeader("Content-Type", "application/octet-stream");
                    headResponse.setHeader("Docker-Content-Digest", digest);
                    headResponse.setHeader("Content-Length", manifestEntry.layerSize.toString());
                    return headResponse;
                }
                // Manifest evicted — still a known digest, just no cached size.
                http:Response headResponse = new;
                headResponse.statusCode = 200;
                headResponse.setHeader("Content-Type", "application/octet-stream");
                headResponse.setHeader("Docker-Content-Digest", digest);
                return headResponse;
            }
        }

        return buildRegistryErrorResponse(404, "BLOB_UNKNOWN", "blob unknown to registry");
    }

    resource function get v2/[string org]/[string name]/blobs/[string digest]() returns http:Response|error {
        log:printDebug("Received request for blob", org = org, name = name, digest = digest);

        if digest == OCI_EMPTY_CONFIG_DIGEST {
            http:Response configResponse = new;
            configResponse.statusCode = 200;
            configResponse.setTextPayload("{}", contentType = "application/vnd.oci.image.config.v1+json");
            return configResponse;
        }

        if blobCache.hasKey(digest) {
            any|cache:Error cacheEntry = blobCache.get(digest);
            if cacheEntry is byte[] {
                log:printDebug("Serving blob from cache", digest = digest);
                return buildBlobResponse(cacheEntry.clone(), digest, "application/octet-stream");
            }
        }

        IndexSource? indexSource = ();
        string? sourceKey = ();
        if blobSources.hasKey(digest) {
            any|cache:Error sourceEntry = blobSources.get(digest);
            if sourceEntry is IndexSource {
                indexSource = sourceEntry;
            } else if sourceEntry is string {
                sourceKey = sourceEntry;
            }
        }
        if indexSource is IndexSource {
            return serveIndexBlob(indexSource, digest);
        }
        if sourceKey is () {
            log:printWarn("Unknown blob digest", digest = digest);
            return buildRegistryErrorResponse(404, "BLOB_UNKNOWN", "blob unknown to registry");
        }

        string[] parts = re `/`.split(sourceKey);

        if parts.length() == 3 {
            string decodedOrg = parts[0];
            string decodedName = parts[1];
            string decodedVersion = parts[2];
            log:printDebug("Serving bala blob", org = decodedOrg, name = decodedName, version = decodedVersion);
            VersionMetadata|http:Response|error metadataResult =
                    resolveVersionMetadata(decodedOrg, decodedName, decodedVersion);
            if metadataResult is http:Response {
                return metadataResult;
            }
            if metadataResult is error {
                log:printError("Failed resolving balaURL", 'error = metadataResult, org = decodedOrg,
                        name = decodedName, version = decodedVersion);
                return buildUpstreamErrorResponse();
            }
            if metadataResult.digest != digest {
                log:printWarn("Bala digest reported by central no longer matches", expected = digest,
                        actual = metadataResult.digest, org = decodedOrg, name = decodedName, version = decodedVersion);
                return buildRegistryErrorResponse(404, "BLOB_UNKNOWN", "blob unknown to registry");
            }
            http:Response redirect = new;
            redirect.statusCode = 307;
            redirect.setHeader("Location", metadataResult.balaURL);
            redirect.setHeader("Docker-Content-Digest", digest);
            log:printDebug("Redirecting to bala download", digest = digest);
            return redirect;
        } else {
            log:printError("Unexpected blob source format", sourceKey = sourceKey);
            return buildRegistryErrorResponse(404, "BLOB_UNKNOWN", "blob unknown to registry");
        }
    }
}