import ballerina/cache;
import ballerina/http;
import ballerina/crypto;
import ballerina/log;

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

// Resolves the balaURL for a specific package version from Ballerina Central metadata.
isolated function resolveBalaURL(string org, string name, string version) returns string|http:Response|error {
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
    return balaURL;
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

// Builds and returns the OCI manifest HTTP response.
isolated function buildOciManifest(string digest, int layerSize) returns http:Response {
    string ociManifest = string `{
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
        ]
    }`;

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
    byte[] versionsBytes;

    if versionsListCache.hasKey(listKey) {
        any|cache:Error cacheEntry = versionsListCache.get(listKey);
        if cacheEntry is string {
            versionsBytes = cacheEntry.toBytes();
            log:printInfo("Versions list served from cache", org = org, name = name);
        } else {
            versionsBytes = [];
        }
    } else {
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
    string digest;
    string balaURL;

    // Check metadata cache first to avoid redundant Central API calls
    if versionMetaCache.hasKey(metaKey) {
        any|cache:Error metaEntry = versionMetaCache.get(metaKey);
        string cached = metaEntry is string ? metaEntry : "";
        int? sepIdxOpt = cached.indexOf("|");
        int sepIdx = sepIdxOpt is int ? sepIdxOpt : -1;
        if sepIdx > 0 {
            digest = cached.substring(0, sepIdx);
            balaURL = cached.substring(sepIdx + 1);
            log:printInfo("Version metadata served from cache", org = org, name = name, version = version, digest = digest);
        } else {
            // Malformed cache entry — fall through to re-fetch
            digest = "";
            balaURL = "";
        }
    } else {
        digest = "";
        balaURL = "";
    }

    if digest == "" || balaURL == "" {
        // Fetch balaURL and digest from Central
        string|http:Response|error balaURLResult = resolveBalaURL(org, name, version);
        if balaURLResult is http:Response {
            return balaURLResult;
        }
        if balaURLResult is error {
            log:printError("Failed resolving balaURL", 'error = balaURLResult, org = org, name = name, version = version);
            http:Response errResponse = new;
            errResponse.statusCode = 502;
            errResponse.setTextPayload("Failed to resolve bala URL: " + balaURLResult.message());
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
        balaURL = balaURLResult;
        // Store digest|balaURL in metadata cache
        cache:Error? cacheErr = versionMetaCache.put(metaKey, string `${digest}|${balaURL}`, -1);
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
    log:printInfo("Built version manifest", org = org, name = name, version = version, digest = digest);
    return buildOciManifest(digest, 0);
}