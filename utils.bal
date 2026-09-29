import ballerina/cache;
import ballerina/http;
import ballerina/crypto;
import ballerina/log;
import ballerina/lang.regexp;
import ballerina/url;

final string DEP_GRAPH_ARTIFACT_TYPE = "application/vnd.ballerina.dependency-graph.v1+json";

// All JvmTarget codes (io.ballerina.projects.JvmTarget); keep in sync.
final string ALL_JVM_PLATFORMS = "java25,java21,java17,java11";

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

isolated function computeSha256Digest(byte[] content) returns string {
    byte[] digestBytes = crypto:hashSha256(content);
    return "sha256:" + bytesToHex(digestBytes);
}

isolated function cachePut(cache:Cache targetCache, string key, any value, string description) {
    cache:Error? cacheErr = targetCache.put(key, value, -1);
    if cacheErr is cache:Error {
        log:printWarn("Failed to cache " + description, key = key, 'error = cacheErr);
    }
}

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

isolated function buildRegistryErrorResponse(int statusCode, string code, string message) returns http:Response {
    http:Response errResponse = new;
    errResponse.statusCode = statusCode;
    errResponse.setJsonPayload({"errors": [{"code": code, "message": message}]});
    return errResponse;
}

// Generic 502 for upstream failures; details go to the logs, not to the client.
isolated function buildUpstreamErrorResponse() returns http:Response {
    return buildRegistryErrorResponse(502, "UNKNOWN", "upstream registry unavailable");
}

// Caps untrusted/unbounded text (e.g. upstream response bodies) before logging it.
isolated function truncateForLog(string value, int maxLength = 512) returns string {
    return value.length() <= maxLength ? value : value.substring(0, maxLength) + "...(truncated)";
}

// "v2201-13-0" -> "2201.13.0"; returns () for non-index tags (e.g. "1.2.3").
isolated function indexTagToDistribution(string reference) returns string? {
    regexp:Groups? groups = re `v(\d+)-(\d+)-(\d+)`.fullMatchGroups(reference);
    if groups is () {
        return ();
    }
    regexp:Span? major = groups[1];
    regexp:Span? minor = groups[2];
    regexp:Span? patch = groups[3];
    if major is () || minor is () || patch is () {
        return ();
    }
    return string `${major.substring()}.${minor.substring()}.${patch.substring()}`;
}

// Path params arrive URL-decoded, so re-encode before building Central URLs; otherwise a request
// like `foo%2F..%2Fbar` would reach other Central endpoints. url:encode is form encoding
// (space -> "+"), so "+" is switched to "%20" to be correct in a path segment.
isolated function encodePathSegment(string value) returns string|error {
    string encoded = check url:encode(value, "UTF-8");
    return re `\+`.replaceAll(encoded, "%20");
}

// When distribution is given, sends User-Agent + Ballerina-Platform so Central filters by it.
isolated function fetchVersionsFromCentral(string org, string name, string distribution = "")
        returns string[]|http:Response|error {
    map<string> headers = {};
    if distribution != "" {
        headers["User-Agent"] = distribution;
        headers["Ballerina-Platform"] = ALL_JVM_PLATFORMS;
    }
    string encodedOrg = check encodePathSegment(org);
    string encodedName = check encodePathSegment(name);
    http:Response centralResponse = check centralClient->get(
        string `/2.0/registry/packages/${encodedOrg}/${encodedName}`, headers
    );

    if centralResponse.statusCode == 404 {
        log:printDebug("Package not found in central", org = org, name = name);
        http:Response notFound = new;
        notFound.statusCode = 404;
        notFound.setTextPayload(string `Package '${org}/${name}' does not exist`, contentType = "text/plain");
        return notFound;
    }
    if centralResponse.statusCode != 200 {
        return error(string `central returned HTTP ${centralResponse.statusCode} for ${org}/${name}`);
    }

    json responsePayload = check centralResponse.getJsonPayload();
    log:printDebug("Fetched versions from central", org = org, name = name);

    // Central returns a JSON object with a `message` field for unknown packages.
    if responsePayload is map<json> {
        json messageField = responsePayload["message"];
        if messageField is string {
            log:printDebug("Package not found in central (message response)", org = org, name = name, centralMessage = messageField);
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

isolated function resolveVersionMetadata(string org, string name, string version)
        returns VersionMetadata|http:Response|error {
    string encodedOrg = check encodePathSegment(org);
    string encodedName = check encodePathSegment(name);
    string encodedVersion = check encodePathSegment(version);
    http:Response versionMetadataResponse = check centralClient->get(
        string `/2.0/registry/packages/${encodedOrg}/${encodedName}/${encodedVersion}`
    );

    if versionMetadataResponse.statusCode == 404 {
        log:printDebug("Package not found in central", org = org, name = name, version = version);
        http:Response notFound = new;
        notFound.statusCode = 404;
        notFound.setTextPayload(string `Package '${org}/${name}:${version}' does not exist`, contentType = "text/plain");
        return notFound;
    }
    if versionMetadataResponse.statusCode != 200 {
        return error(string `central returned HTTP ${versionMetadataResponse.statusCode} for ${org}/${name}:${version}`);
    }

    json responsePayload = check versionMetadataResponse.getJsonPayload();
    log:printDebug("Fetched metadata from central", org = org, name = name, version = version);

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

    string? rawDigest = getStringField(versionData, "digest");
    if rawDigest is () {
        return error("Central version metadata did not contain a digest field");
    }
    string digest = re `sha-256=`.replaceAll(rawDigest, "sha256:"); // Central: "sha-256=<hex>" -> OCI: "sha256:<hex>"

    string platform = getStringField(versionData, "platform") ?: "";
    string distributionVersion = getStringField(versionData, "ballerinaVersion") ?: "";
    boolean isDeprecated = getBooleanField(versionData, "isDeprecated") ?: false;
    string deprecateMessage = getStringField(versionData, "deprecateMessage") ?: "";
    string[] modules = getModuleNames(versionData);
    return {balaURL, digest, platform, distributionVersion, isDeprecated, deprecateMessage, modules};
}

isolated function getModuleNames(map<json> versionData) returns string[] {
    json modulesField = versionData["modules"];
    if modulesField !is json[] {
        return [];
    }
    string[] names = [];
    foreach json module in modulesField {
        if module is map<json> {
            string? name = getStringField(module, "name");
            if name is string {
                names.push(name);
            }
        }
    }
    return names;
}

isolated function splitBalaURL(string balaURL) returns [string, string] {
    int? pathStart = balaURL.indexOf("/", 8); // skip "https://"
    if pathStart is int {
        return [balaURL.substring(0, pathStart), balaURL.substring(pathStart)];
    }
    return [balaURL, "/"];
}

// HEAD the CDN URL to get the bala size without downloading it.
isolated function fetchBalaSize(string balaURL) returns int|error {
    [string, string] [balaBase, balaPath] = splitBalaURL(balaURL);
    http:Client balaClient = check new (balaBase, {timeout: balaCdnTimeout});
    http:Response balaResponse = check balaClient->head(balaPath);
    if balaResponse.statusCode != 200 {
        return error(string `bala HEAD returned HTTP ${balaResponse.statusCode}`);
    }
    string contentLength = check balaResponse.getHeader("Content-Length");
    return int:fromString(contentLength);
}

isolated function getStringField(map<json> data, string fieldName) returns string? {
    json? fieldValue = data[fieldName];
    if fieldValue is string {
        return fieldValue;
    }
    return ();
}

isolated function getBooleanField(map<json> data, string fieldName) returns boolean? {
    json? fieldValue = data[fieldName];
    if fieldValue is boolean {
        return fieldValue;
    }
    return ();
}

// Escapes free-text values (e.g. deprecation messages) for embedding in hand-built JSON.
isolated function jsonEscape(string value) returns string {
    string escaped = re `\\`.replaceAll(value, "\\\\");
    escaped = re `"`.replaceAll(escaped, "\\\"");
    escaped = re `\n`.replaceAll(escaped, "\\n");
    escaped = re `\r`.replaceAll(escaped, "\\r");
    escaped = re `\t`.replaceAll(escaped, "\\t");
    return escaped;
}

// Omit platform/distributionVersion for index manifests (no annotations needed).
isolated function buildOciManifestText(string digest, int layerSize, string platform = "",
        string distributionVersion = "", boolean isDeprecated = false, string deprecateMessage = "",
        string[] modules = []) returns string {
    string annotations = "";
    if platform != "" {
        // Module names have no commas, so a CSV list is safe.
        string moduleAnnotation = modules.length() == 0 ? "" : string `,
            "io.ballerina.modules": "${jsonEscape(",".'join(...modules))}"`;
        annotations = string `,
        "annotations": {
            "io.ballerina.platform": "${platform}",
            "io.ballerina.distribution": "${distributionVersion}",
            "io.ballerina.deprecated": "${isDeprecated.toString()}",
            "io.ballerina.deprecation-message": "${jsonEscape(deprecateMessage)}"${moduleAnnotation}
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

isolated function buildManifestResponse(string digest, string manifestText) returns http:Response {
    http:Response manifestResponse = new;
    manifestResponse.statusCode = 200;
    manifestResponse.setHeader("Content-Type", "application/vnd.oci.image.manifest.v1+json");
    manifestResponse.setHeader("Docker-Content-Digest", digest);
    manifestResponse.setHeader("ETag", "\"" + digest + "\"");
    manifestResponse.setTextPayload(manifestText, contentType = "application/vnd.oci.image.manifest.v1+json");
    return manifestResponse;
}

isolated function toHeadResponse(http:Response getResponse) returns http:Response|error {
    if getResponse.statusCode != 200 {
        return getResponse;
    }
    string digest = check getResponse.getHeader("Docker-Content-Digest");
    byte[] body = check getResponse.getBinaryPayload();
    http:Response headResponse = new;
    headResponse.statusCode = 200;
    headResponse.setHeader("Content-Type", "application/vnd.oci.image.manifest.v1+json");
    headResponse.setHeader("Docker-Content-Digest", digest);
    headResponse.setHeader("ETag", "\"" + digest + "\"");
    headResponse.setHeader("Content-Length", body.length().toString());
    return headResponse;
}

function buildIndexManifestResponse(string org, string name, string distribution = "")
        returns http:Response|error {
    string listKey = string `${org}/${name}@${distribution}`;
    byte[] versionsBytes = [];

    boolean cacheHit = false;
    if versionsListCache.hasKey(listKey) {
        any|cache:Error cacheEntry = versionsListCache.get(listKey);
        if cacheEntry is string {
            versionsBytes = cacheEntry.toBytes();
            log:printDebug("Versions list served from cache", org = org, name = name);
            cacheHit = true;
        }
    }

    if !cacheHit {
        string[]|http:Response|error fetchResult = fetchVersionsFromCentral(org, name, distribution);
        if fetchResult is http:Response {
            return fetchResult;
        }
        if fetchResult is error {
            log:printError("Failed fetching versions from central", 'error = fetchResult, org = org, name = name,
                    distribution = distribution);
            return buildUpstreamErrorResponse();
        }
        if fetchResult.length() == 0 {
            http:Response notFound = new;
            notFound.statusCode = 404;
            notFound.setTextPayload(string `Package '${org}/${name}' has no published versions`, contentType = "text/plain");
            return notFound;
        }
        string versionsJson = fetchResult.toJsonString();
        versionsBytes = versionsJson.toBytes();
        cachePut(versionsListCache, listKey, versionsJson, "versions list");
    }

    string versionsDigest = computeSha256Digest(versionsBytes);
    cachePut(blobCache, versionsDigest, versionsBytes, "versions blob");
    IndexSource indexSource = {org, name, distribution};
    cachePut(blobSources, versionsDigest, indexSource, "versions source");

    string manifestText = buildOciManifestText(versionsDigest, versionsBytes.length());
    string manifestDigest = computeSha256Digest(manifestText.toBytes());
    cachePut(manifestsByDigest, manifestDigest, manifestText, "index manifest");
    log:printDebug("Built index manifest", org = org, name = name, distribution = distribution,
            digest = manifestDigest);
    return buildManifestResponse(manifestDigest, manifestText);
}

function buildVersionManifest(string org, string name, string version)
        returns VersionManifest|http:Response|error {
    VersionMetadata|http:Response metadata = check resolveVersionMetadata(org, name, version);
    if metadata is http:Response {
        return metadata;
    }
    int balaSize = check fetchBalaSize(metadata.balaURL);
    string manifestText = buildOciManifestText(metadata.digest, balaSize, metadata.platform,
            metadata.distributionVersion, metadata.isDeprecated, metadata.deprecateMessage, metadata.modules);
    VersionManifest manifest = {
        manifestText,
        manifestDigest: computeSha256Digest(manifestText.toBytes()),
        layerDigest: metadata.digest,
        layerSize: balaSize
    };
    cachePut(versionMetaCache, string `${org}/${name}/${version}`, manifest, "version manifest");
    log:printDebug("Built version manifest", org = org, name = name, version = version,
            digest = manifest.manifestDigest, platform = metadata.platform,
            distributionVersion = metadata.distributionVersion, isDeprecated = metadata.isDeprecated);
    return manifest;
}

function getVersionManifest(string org, string name, string version) returns VersionManifest|http:Response {
    string metaKey = string `${org}/${name}/${version}`;
    VersionManifest? cached = ();
    if versionMetaCache.hasKey(metaKey) {
        any|cache:Error metaEntry = versionMetaCache.get(metaKey);
        if metaEntry is VersionManifest {
            cached = metaEntry;
            log:printDebug("Version manifest served from cache", org = org, name = name, version = version);
        }
    }

    VersionManifest|http:Response|error result = cached is VersionManifest
        ? cached : buildVersionManifest(org, name, version);
    if result is error {
        log:printError("Failed building version manifest", 'error = result, org = org, name = name, version = version);
        return buildUpstreamErrorResponse();
    }
    if result is http:Response {
        return result;
    }

    cachePut(blobSources, result.layerDigest, metaKey, "blob source");
    // Referrers queries carry only the manifest digest — this is the only way back to org/name/version.
    SubjectManifestInfo subjectInfo = {metaKey, size: result.manifestText.toBytes().length()};
    cachePut(subjectManifestSources, result.manifestDigest, subjectInfo, "subject manifest source");
    cachePut(manifestsByDigest, result.manifestDigest, result.manifestText, "version manifest by digest");
    return result;
}

function buildVersionManifestResponse(string org, string name, string version) returns http:Response {
    VersionManifest|http:Response manifest = getVersionManifest(org, name, version);
    if manifest is http:Response {
        return manifest;
    }
    return buildManifestResponse(manifest.manifestDigest, manifest.manifestText);
}

isolated function fetchDependencyGraphFromCentral(string org, string name, string version)
        returns ResolvedPackage|http:Response|error {
    PackageResolutionRequest requestBody = {
        packages: [{org, name, 'version: version, mode: "hard"}]
    };

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
                status = resolutionResponse.statusCode, body = truncateForLog(responseBody));
        return buildUpstreamErrorResponse();
    }

    json responsePayload = check resolutionResponse.getJsonPayload();
    PackageResolutionResponse resolution = check responsePayload.cloneWithType();
    if resolution.resolved.length() == 0 {
        return error(string `central did not resolve ${org}/${name}:${version}`);
    }
    return resolution.resolved[0];
}

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

    // Shape must match bala's dependency-graph.json; `modules` must be present (client doesn't null-check it).
    json dependencyGraphJson = {"packages": resolved.dependencyGraph.toJson(), "modules": []};
    byte[] graphBytes = dependencyGraphJson.toJsonString().toBytes();
    string graphDigest = computeSha256Digest(graphBytes);
    cachePut(blobCache, graphDigest, graphBytes, "dependency graph blob");

    string manifestText = buildDependencyGraphManifestText(subjectDigest, subjectSize, graphDigest,
            graphBytes.length());
    byte[] manifestBytes = manifestText.toBytes();
    string manifestDigest = computeSha256Digest(manifestBytes);
    cachePut(manifestsByDigest, manifestDigest, manifestText, "dependency graph referrer manifest");

    ReferrerInfo referrerInfo = {manifestDigest, manifestSize: manifestBytes.length()};
    cachePut(depGraphMetaCache, subjectDigest, referrerInfo, "dependency graph referrer info");
    log:printDebug("Built dependency graph referrer", org = org, name = name, version = version,
            manifestDigest = manifestDigest);
    return referrerInfo;
}

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

function getManifestByDigest(string reference) returns http:Response? {
    if !reference.startsWith("sha256:") || !manifestsByDigest.hasKey(reference) {
        return ();
    }
    any|cache:Error cachedManifest = manifestsByDigest.get(reference);
    return cachedManifest is string ? buildManifestResponse(reference, cachedManifest) : ();
}

// Re-fetches from Central on cache miss; returns 404 if the list changed (digest mismatch).
function serveIndexBlob(IndexSource indexSource, string digest) returns http:Response {
    string[]|http:Response|error versionsResult = fetchVersionsFromCentral(indexSource.org, indexSource.name,
            indexSource.distribution);
    if versionsResult is http:Response {
        return versionsResult;
    }
    if versionsResult is error {
        log:printError("Failed fetching versions from central", 'error = versionsResult, org = indexSource.org,
                name = indexSource.name, distribution = indexSource.distribution);
        return buildUpstreamErrorResponse();
    }

    byte[] versionsBytes = versionsResult.toJsonString().toBytes();
    if computeSha256Digest(versionsBytes) != digest {
        log:printDebug("Versions list changed since its manifest was built", org = indexSource.org,
                name = indexSource.name, distribution = indexSource.distribution, digest = digest);
        return buildRegistryErrorResponse(404, "BLOB_UNKNOWN", "version list has changed");
    }
    cachePut(blobCache, digest, versionsBytes, "versions blob");
    log:printDebug("Serving versions blob", digest = digest, size = versionsBytes.length());
    return buildBlobResponse(versionsBytes, digest, "application/octet-stream");
}
