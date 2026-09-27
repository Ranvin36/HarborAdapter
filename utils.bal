import ballerina/cache;
import ballerina/http;
import ballerina/crypto;
import ballerina/log;
import ballerina/url;

final string DEP_GRAPH_ARTIFACT_TYPE = "application/vnd.ballerina.dependency-graph.v1+json";

// Converts a byte array to a lowercase hex string.
isolated function bytesToHex(byte[] input) returns string {
    string hexChars = "0123456789abcdef";
    string hexEncoded = "";
    foreach byte b in input {
        int highNibble = (b & 0xF0) >> 4;
        int lowNibble = b & 0x0F;
        hexEncoded = hexEncoded + hexChars.substring(highNibble, highNibble + 1)
                                + hexChars.substring(lowNibble, lowNibble + 1);
    }
    return hexEncoded;
}

// Computes a content-addressable OCI digest for a blob.
isolated function computeSha256Digest(byte[] content) returns string {
    byte[] digestBytes = crypto:hashSha256(content);
    return "sha256:" + bytesToHex(digestBytes);
}

// Builds a blob response with OCI-friendly headers.
isolated function buildBlobResponse(byte[] content, string digest, string contentType) returns http:Response {
    http:Response blobResponse = new;
    blobResponse.statusCode = 200;
    blobResponse.setHeader("Content-Type", contentType);
    blobResponse.setHeader("Docker-Content-Digest", digest);
    blobResponse.setHeader("ETag", "\"" + digest + "\"");
    blobResponse.setHeader("Content-Length", content.length().toString());
    blobResponse.setBinaryPayload(content);
    return blobResponse;
}

// Fetches the list of versions for a package from Ballerina Central.
isolated function fetchVersionsFromCentral(string org, string name) returns string[]|http:Response|error {
    http:Response centralResponse = check centralClient->get(
        string `/2.0/registry/packages/${org}/${name}`
    );

    if centralResponse.statusCode == 404 {
        log:printInfo("Package not found in central", org = org, name = name);
        http:Response notFound = new;
        notFound.statusCode = 404;
        notFound.setTextPayload(string `Package '${org}/${name}' does not exist`, contentType = "text/plain");
        return notFound;
    }

    json responsePayload = check centralResponse.getJsonPayload();
    log:printInfo("Fetched versions from central", org = org, name = name, response = responsePayload);

    // Central returns a JSON object with a `message` field when the package is not found.
    if responsePayload is map<json> {
        json messageField = responsePayload["message"];
        if messageField is string {
            log:printInfo("Package not found in central (message response)", org = org, name = name, centralMessage = messageField);
            http:Response notFound = new;
            notFound.statusCode = 404;
            notFound.setTextPayload(string `Package '${org}/${name}' does not exist`, contentType = "text/plain");
            return notFound;
        }
        VersionsResponse versionsData = check responsePayload.cloneWithType();
        return versionsData.versions;
    }

    string[] versionList = check responsePayload.cloneWithType();
    return versionList;
}

// Resolves version metadata (bala URL, platform, distribution) for a specific package version
// from Ballerina Central. Platform/distribution default to "" rather than failing the whole
// lookup if Central's response happens not to carry them — they only drive manifest annotations,
// balaURL is the one field the caller cannot proceed without.
isolated function resolveBalaURL(string org, string name, string version) returns VersionMetadata|http:Response|error {
    http:Response versionMetadataResponse = check centralClient->get(
        string `/2.0/registry/packages/${org}/${name}/${version}`
    );

    if versionMetadataResponse.statusCode == 404 {
        log:printInfo("Package not found in central", org = org, name = name, version = version);
        http:Response notFound = new;
        notFound.statusCode = 404;
        notFound.setTextPayload(string `Package '${org}/${name}:${version}' does not exist`, contentType = "text/plain");
        return notFound;
    }

    json responsePayload = check versionMetadataResponse.getJsonPayload();
    log:printInfo("Fetched metadata from central", org = org, name = name, version = version);

    map<json> versionData = check responsePayload.cloneWithType();
    string? balaURL = getStringField(versionData, "balaURL");
    if balaURL is () {
        balaURL = getStringField(versionData, "balURL");
    }
    if balaURL is () {
        balaURL = getStringField(versionData, "URL");
    }
    if balaURL is () {
        return error("Central version metadata did not contain a balaURL, balURL, or URL field");
    }

    string platform = getStringField(versionData, "platform") ?: "";
    string distributionVersion = getStringField(versionData, "ballerinaVersion") ?: "";
    boolean isDeprecated = getBooleanField(versionData, "isDeprecated") ?: false;
    string deprecateMessage = getStringField(versionData, "deprecateMessage") ?: "";
    return {balaURL, platform, distributionVersion, isDeprecated, deprecateMessage};
}

// Downloads bala bytes from a presigned CDN URL.
isolated function downloadBalaBytes(string balaURL) returns byte[]|error {
    // Split into base (scheme + host) and path+query — preserves presigned query params
    int? pathStart = balaURL.indexOf("/", 8); // skip "https://"
    string balaBase;
    string balaPath;
    if pathStart is int {
        balaBase = balaURL.substring(0, pathStart);
        balaPath = balaURL.substring(pathStart);
    } else {
        balaBase = balaURL;
        balaPath = "/";
    }
    http:Client balaClient = check new (balaBase, {timeout: 50});
    http:Response balaResponse = check balaClient->get(balaPath);
    return check balaResponse.getBinaryPayload();
}

// Reads a string field from a JSON object if it exists.
isolated function getStringField(map<json> data, string fieldName) returns string? {
    json? fieldValue = data[fieldName];
    if fieldValue is string {
        return fieldValue;
    }
    return ();
}

// Reads a boolean field from a JSON object if it exists.
isolated function getBooleanField(map<json> data, string fieldName) returns boolean? {
    json? fieldValue = data[fieldName];
    if fieldValue is boolean {
        return fieldValue;
    }
    return ();
}

// Escapes a string for embedding as a JSON string value inside a hand-built template. Needed for
// the deprecation message specifically, since (unlike platform/distribution, which are
// toolchain-controlled values) it is free text a package owner wrote on Central.
isolated function jsonEscape(string value) returns string {
    string escaped = re `\\`.replaceAll(value, "\\\\");
    escaped = re `"`.replaceAll(escaped, "\\\"");
    escaped = re `\n`.replaceAll(escaped, "\\n");
    escaped = re `\r`.replaceAll(escaped, "\\r");
    escaped = re `\t`.replaceAll(escaped, "\\t");
    return escaped;
}

// Builds the JSON text of an OCI manifest whose single layer points at the given digest.
// Pulled out of buildOciManifest so callers that only need the bytes (e.g. to measure a
// subject manifest's size for a referrers-index entry) don't have to unpack an http:Response.
//
// platform/distributionVersion are optional: the "latest" version-list manifest has no single
// platform/distribution to report, so it's built with both left as "" and no annotations appear.
isolated function buildOciManifestText(string digest, int layerSize, string platform = "",
        string distributionVersion = "", boolean isDeprecated = false, string deprecateMessage = "")
        returns string {
    string annotations = "";
    if platform != "" {
        annotations = string `,
        "annotations": {
            "io.ballerina.platform": "${platform}",
            "io.ballerina.distribution": "${distributionVersion}",
            "io.ballerina.deprecated": "${isDeprecated.toString()}",
            "io.ballerina.deprecation-message": "${jsonEscape(deprecateMessage)}"
        }`;
    }
    return string `{
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": {
            "mediaType": "application/vnd.oci.image.config.v1+json",
            "size": 2,
            "digest": "${OCI_EMPTY_CONFIG_DIGEST}"
        },
        "layers": [
            {
            "mediaType": "application/vnd.ballerina.index.layer.v1+json",
            "size": ${layerSize},
            "digest": "${digest}"
            }
        ]${annotations}
    }`;
}

// Builds and returns the OCI manifest HTTP response.
isolated function buildOciManifest(string digest, int layerSize, string platform = "",
        string distributionVersion = "", boolean isDeprecated = false, string deprecateMessage = "")
        returns http:Response {
    string ociManifest = buildOciManifestText(digest, layerSize, platform, distributionVersion, isDeprecated,
            deprecateMessage);

    http:Response manifestResponse = new;
    manifestResponse.statusCode = 200;
    manifestResponse.setHeader("Content-Type", "application/vnd.oci.image.manifest.v1+json");
    manifestResponse.setHeader("Docker-Content-Digest", digest);
    manifestResponse.setHeader("ETag", "\"" + digest + "\"");
    manifestResponse.setTextPayload(ociManifest, contentType = "application/vnd.oci.image.manifest.v1+json");
    return manifestResponse;
}

// Builds the OCI manifest for the package versions.
function buildLatestManifestResponse(string org, string name) returns http:Response|error {
    string listKey = string `${org}/${name}`;
    byte[] versionsBytes = [];

    boolean cacheHit = false;
    if versionsListCache.hasKey(listKey) {
        any|cache:Error cacheEntry = versionsListCache.get(listKey);
        if cacheEntry is string {
            versionsBytes = cacheEntry.toBytes();
            log:printInfo("Versions list served from cache", org = org, name = name);
            cacheHit = true;
        }
    }

    if !cacheHit {
        string[]|http:Response|error fetchResult = fetchVersionsFromCentral(org, name);
        if fetchResult is http:Response {
            return fetchResult;
        }
        if fetchResult is error {
            log:printError("Failed fetching versions from central", 'error = fetchResult, org = org, name = name);
            http:Response errResponse = new;
            errResponse.statusCode = 502;
            errResponse.setTextPayload("Failed to fetch from central: " + fetchResult.message());
            return errResponse;
        }
        if fetchResult.length() == 0 {
            http:Response errResponse = new;
            errResponse.statusCode = 502;
            errResponse.setTextPayload("No versions available for package");
            return errResponse;
        }
        string versionsJson = fetchResult.toJsonString();
        versionsBytes = versionsJson.toBytes();
        cache:Error? cacheErr = versionsListCache.put(listKey, versionsJson, -1);
        if cacheErr is cache:Error {
            log:printWarn("Failed to cache versions list", org = org, name = name, 'error = cacheErr);
        } else {
            log:printInfo("Cached versions list", org = org, name = name);
        }
    }

    string digest = computeSha256Digest(versionsBytes);
    cache:Error? cacheErr = blobCache.put(digest, versionsBytes, -1);
    if cacheErr is cache:Error {
        log:printWarn("Failed to cache versions blob", digest = digest, 'error = cacheErr);
    }
    cacheErr = blobSources.put(digest, listKey, -1);
    if cacheErr is cache:Error {
        log:printWarn("Failed to cache versions source", digest = digest, 'error = cacheErr);
    }
    log:printInfo("Built latest manifest", org = org, name = name, digest = digest);
    return buildOciManifest(digest, versionsBytes.length());
}

// Fetches only the digest for a package version from Ballerina Central (no bala download).
isolated function fetchVersionDigestFromCentral(string org, string name, string version) returns string|http:Response|error {
    http:Response versionMetadataResponse = check centralClient->get(
        string `/2.0/registry/packages/${org}/${name}/${version}`
    );

    if versionMetadataResponse.statusCode == 404 {
        log:printInfo("Package not found in central", org = org, name = name, version = version);
        http:Response notFound = new;
        notFound.statusCode = 404;
        notFound.setTextPayload(string `Package '${org}/${name}:${version}' does not exist`, contentType = "text/plain");
        return notFound;
    }

    json responsePayload = check versionMetadataResponse.getJsonPayload();
    map<json> versionData = check responsePayload.cloneWithType();

    string? rawDigest = getStringField(versionData, "digest");
    if rawDigest is () {
        return error("Central version metadata did not contain a digest field");
    }

    // Central returns "sha256=<hex>"; convert to OCI format "sha256:<hex>"
    string ociDigest = re `sha-256=`.replaceAll(rawDigest, "sha256:");
    log:printInfo("Fetched version digest from central", org = org, name = name, version = version, digest = ociDigest);
    return ociDigest;
}

// Builds the OCI manifest for a bala package (GET — uses Central digest, defers bala download to blob request).
function buildVersionManifestResponse(string org, string name, string version) returns http:Response|error {
    string metaKey = string `${org}/${name}/${version}`;
    string digest = "";
    string balaURL = "";
    string platform = "";
    string distributionVersion = "";
    boolean isDeprecated = false;
    string deprecateMessage = "";
    boolean cacheHit = false;

    // Check metadata cache first to avoid redundant Central API calls
    if versionMetaCache.hasKey(metaKey) {
        any|cache:Error metaEntry = versionMetaCache.get(metaKey);
        string cached = metaEntry is string ? metaEntry : "";
        string[] parts = re `\|`.split(cached);
        // deprecateMessage is free text and may itself contain "|", so anything from the 6th
        // field onward is rejoined back into the message rather than requiring an exact count.
        if parts.length() >= 6 {
            digest = parts[0];
            balaURL = parts[1];
            platform = parts[2];
            distributionVersion = parts[3];
            isDeprecated = parts[4] == "true";
            deprecateMessage = parts[5];
            foreach int i in 6 ..< parts.length() {
                deprecateMessage = deprecateMessage + "|" + parts[i];
            }
            cacheHit = true;
            log:printInfo("Version metadata served from cache", org = org, name = name, version = version, digest = digest);
        }
        // Otherwise a malformed or pre-upgrade cache entry — fall through to re-fetch.
    }

    if !cacheHit {
        // Fetch balaURL/platform/distribution/deprecation status and digest from Central
        VersionMetadata|http:Response|error metadataResult = resolveBalaURL(org, name, version);
        if metadataResult is http:Response {
            return metadataResult;
        }
        if metadataResult is error {
            log:printError("Failed resolving balaURL", 'error = metadataResult, org = org, name = name, version = version);
            http:Response errResponse = new;
            errResponse.statusCode = 502;
            errResponse.setTextPayload("Failed to resolve bala URL: " + metadataResult.message());
            return errResponse;
        }

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
        balaURL = metadataResult.balaURL;
        platform = metadataResult.platform;
        distributionVersion = metadataResult.distributionVersion;
        isDeprecated = metadataResult.isDeprecated;
        deprecateMessage = metadataResult.deprecateMessage;
        // Store digest|balaURL|platform|distributionVersion|isDeprecated|deprecateMessage in cache
        cache:Error? cacheErr = versionMetaCache.put(metaKey,
                string `${digest}|${balaURL}|${platform}|${distributionVersion}|${isDeprecated.toString()}` +
                        string `|${deprecateMessage}`, -1);
        if cacheErr is cache:Error {
            log:printWarn("Failed to cache version metadata", metaKey = metaKey, 'error = cacheErr);
        } else {
            log:printInfo("Cached version metadata", org = org, name = name, version = version, digest = digest);
        }
    }

    // Cache the source key and balaURL for the blob endpoint
    cache:Error? cacheErr = blobSources.put(digest, metaKey, -1);
    if cacheErr is cache:Error {
        log:printWarn("Failed to cache blob source", digest = digest, 'error = cacheErr);
    }
    cacheErr = blobSources.put(string `url:${digest}`, balaURL, -1);
    if cacheErr is cache:Error {
        log:printWarn("Failed to cache balaURL", digest = digest, 'error = cacheErr);
    }

    // Record this manifest's own (self) digest so a later `GET referrers/{selfDigest}` — which
    // only ever carries a digest, never org/name/version — can find its way back to this package.
    // Must match buildOciManifest's own call below exactly, or the self-digest recorded here won't
    // match what's actually served, breaking the referrers lookup.
    string manifestText = buildOciManifestText(digest, 0, platform, distributionVersion, isDeprecated,
            deprecateMessage);
    string selfDigest = computeSha256Digest(manifestText.toBytes());
    SubjectManifestInfo subjectInfo = {metaKey, size: manifestText.toBytes().length()};
    cacheErr = subjectManifestSources.put(selfDigest, subjectInfo, -1);
    if cacheErr is cache:Error {
        log:printWarn("Failed to cache subject manifest source", digest = selfDigest, 'error = cacheErr);
    }

    log:printInfo("Built version manifest", org = org, name = name, version = version, digest = digest,
            platform = platform, distributionVersion = distributionVersion, isDeprecated = isDeprecated);
    return buildOciManifest(digest, 0, platform, distributionVersion, isDeprecated, deprecateMessage);
}

// Fetches the dependency graph for one package version from Central's dedicated
// resolve-dependencies endpoint. This never downloads the bala — the graph is Central's own
// small, purpose-built response, so there's nothing here worth caching beyond the referrer
// artifact this produces (see buildDependencyGraphReferrer).
isolated function fetchDependencyGraphFromCentral(string org, string name, string version)
        returns ResolvedPackage|http:Response|error {
    // Central's own client (PackageResolutionRequest.addPackage) URL-encodes the version before
    // sending it, to avoid the dash in pre-release tags tripping up its parsing — mirrored here.
    string encodedVersion = check url:encode(version, "UTF-8");
    PackageResolutionRequest requestBody = {
        packages: [{org, name, 'version: encodedVersion, mode: "hard"}]
    };

    // Central's real client (CentralAPIClient.getNewRequest) always sends these; resolve-dependencies
    // uses Ballerina-Platform to pick compatible bala variants, and appears to reject requests
    // that omit it.
    http:Request resolutionRequest = new;
    resolutionRequest.setJsonPayload(requestBody.toJson());
    resolutionRequest.setHeader("Ballerina-Platform", "any");
    resolutionRequest.setHeader("User-Agent", "HarborAdapter/0.1.0");
    resolutionRequest.setHeader("Accept", "application/json");

    http:Response resolutionResponse = check centralClient->post(
        "/2.0/registry/packages/resolve-dependencies", resolutionRequest
    );

    if resolutionResponse.statusCode != 200 {
        string responseBody = "";
        string|error textPayload = resolutionResponse.getTextPayload();
        if textPayload is string {
            responseBody = textPayload;
        }
        log:printWarn("Central resolve-dependencies call failed", org = org, name = name, version = version,
                status = resolutionResponse.statusCode, body = responseBody);
        http:Response errResponse = new;
        errResponse.statusCode = 502;
        errResponse.setTextPayload("Failed to resolve dependency graph from central: " + responseBody);
        return errResponse;
    }

    json responsePayload = check resolutionResponse.getJsonPayload();
    PackageResolutionResponse resolution = check responsePayload.cloneWithType();
    if resolution.resolved.length() == 0 {
        return error(string `central did not resolve ${org}/${name}:${version}`);
    }
    return resolution.resolved[0];
}

// Builds the JSON text of a referrer manifest whose `subject` points at another manifest.
isolated function buildDependencyGraphManifestText(string subjectDigest, int subjectSize,
        string layerDigest, int layerSize) returns string {
    return string `{
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "artifactType": "${DEP_GRAPH_ARTIFACT_TYPE}",
        "config": {
            "mediaType": "application/vnd.oci.empty.v1+json",
            "size": 2,
            "digest": "${OCI_EMPTY_CONFIG_DIGEST}"
        },
        "layers": [
            {
            "mediaType": "${DEP_GRAPH_ARTIFACT_TYPE}",
            "size": ${layerSize},
            "digest": "${layerDigest}"
            }
        ],
        "subject": {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": "${subjectDigest}",
            "size": ${subjectSize}
        }
    }`;
}

// Returns the dependency-graph referrer for one package version, building and caching it on
// first use. A cache hit skips the Central call entirely; a miss costs one small REST call
// (never a bala download) and is bounded by depGraphMetaCache's normal capacity/TTL — there is
// deliberately no "cache forever" here, since a miss is cheap enough not to need one.
// Not `isolated`: it mutates the module-level caches, same as buildVersionManifestResponse.
function buildDependencyGraphReferrer(string org, string name, string version,
        string subjectDigest, int subjectSize) returns ReferrerInfo|http:Response|error {
    if depGraphMetaCache.hasKey(subjectDigest) {
        any|cache:Error cached = depGraphMetaCache.get(subjectDigest);
        if cached is ReferrerInfo {
            return cached;
        }
    }

    ResolvedPackage|http:Response|error resolved = fetchDependencyGraphFromCentral(org, name, version);
    if resolved is http:Response {
        return resolved;
    }
    if resolved is error {
        return resolved;
    }

    byte[] graphBytes = resolved.toJsonString().toBytes();
    string graphDigest = computeSha256Digest(graphBytes);
    // Reuses the blob endpoint's existing blobCache-hit fast path — no blobSources entry needed.
    cache:Error? cacheErr = blobCache.put(graphDigest, graphBytes, -1);
    if cacheErr is cache:Error {
        log:printWarn("Failed to cache dependency graph blob", digest = graphDigest, 'error = cacheErr);
    }

    string manifestText = buildDependencyGraphManifestText(subjectDigest, subjectSize, graphDigest,
            graphBytes.length());
    byte[] manifestBytes = manifestText.toBytes();
    string manifestDigest = computeSha256Digest(manifestBytes);

    cacheErr = referrerManifestCache.put(manifestDigest, manifestText, -1);
    if cacheErr is cache:Error {
        log:printWarn("Failed to cache dependency graph referrer manifest", digest = manifestDigest,
                'error = cacheErr);
    }

    ReferrerInfo referrerInfo = {manifestDigest, manifestSize: manifestBytes.length()};
    cacheErr = depGraphMetaCache.put(subjectDigest, referrerInfo, -1);
    if cacheErr is cache:Error {
        log:printWarn("Failed to cache dependency graph referrer info", digest = subjectDigest, 'error = cacheErr);
    }
    log:printInfo("Built dependency graph referrer", org = org, name = name, version = version,
            manifestDigest = manifestDigest);
    return referrerInfo;
}

// Serves a manifest whose bytes are already known (a cached referrer manifest), verbatim.
isolated function buildCachedManifestResponse(string digest, string manifestText) returns http:Response {
    http:Response manifestResponse = new;
    manifestResponse.statusCode = 200;
    manifestResponse.setHeader("Content-Type", "application/vnd.oci.image.manifest.v1+json");
    manifestResponse.setHeader("Docker-Content-Digest", digest);
    manifestResponse.setHeader("ETag", "\"" + digest + "\"");
    manifestResponse.setTextPayload(manifestText, contentType = "application/vnd.oci.image.manifest.v1+json");
    return manifestResponse;
}

// Builds the OCI image index returned by the referrers API.
isolated function buildReferrersIndexResponse(ReferrerInfo[] referrers) returns http:Response {
    json[] manifestDescriptors = referrers.map(r => {
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "size": r.manifestSize,
        "digest": r.manifestDigest,
        "artifactType": DEP_GRAPH_ARTIFACT_TYPE
    });
    json index = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": manifestDescriptors
    };
    http:Response response = new;
    response.statusCode = 200;
    response.setHeader("Content-Type", "application/vnd.oci.image.index.v1+json");
    response.setJsonPayload(index);
    return response;
}