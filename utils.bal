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

// Fetches the bala bytes for a specific package version from Ballerina Central.
isolated function fetchBalaFromCentral(string org, string name, string version) returns byte[]|http:Response|error {
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

    // Split balaURL into base (scheme + host) and path+query to avoid client mishandling presigned URLs

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
    byte[] balaBytes = check balaResponse.getBinaryPayload();
    log:printInfo("Fetched bala bytes", org = org, name = name, version = version, size = balaBytes.length());
    return balaBytes;
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

    byte[] versionsBytes = fetchResult.toJsonString().toBytes();
    string digest = computeSha256Digest(versionsBytes);
    lock {
        blobCache[digest] = versionsBytes.clone();
    }
    lock {
        blobSources[digest] = string `${org}/${name}`;
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
    string ociDigest = re `sha256=`.replaceAll(rawDigest, "sha256:");
    log:printInfo("Fetched version digest from central", org = org, name = name, version = version, digest = ociDigest);
    return ociDigest;
}

// Builds the OCI manifest for a bala package (GET — downloads bala, computes real digest and size).
function buildVersionManifestResponse(string org, string name, string version) returns http:Response|error {
    byte[]|http:Response|error balaResult = fetchBalaFromCentral(org, name, version);
    if balaResult is http:Response {
        return balaResult;
    }
    if balaResult is error {
        log:printError("Failed fetching bala for manifest", 'error = balaResult, org = org, name = name, version = version);
        http:Response errResponse = new;
        errResponse.statusCode = 502;
        errResponse.setTextPayload("Failed to fetch bala: " + balaResult.message());
        return errResponse;
    }

    string digest = computeSha256Digest(balaResult);
    lock {
        blobCache[digest] = balaResult.clone();
    }
    lock {
        blobSources[digest] = string `${org}/${name}/${version}`;
    }
    log:printInfo("Built version manifest", org = org, name = name, version = version, digest = digest, size = balaResult.length());
    return buildOciManifest(digest, balaResult.length());
}