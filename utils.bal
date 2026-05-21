import ballerina/http;
import ballerina/crypto;
import ballerina/log;

// Fetches the list of versions for a package from Ballerina Central
isolated function fetchVersionsFromCentral(string org, string name) returns string[]|http:Response|error {
    http:Response centralResponse = check centralClient->get(
        string `/2.0/registry/packages/${org}/${name}`
    );

    if centralResponse.statusCode == 404 {
        log:printInfo("Package not found in central", org = org, name = name);
        http:Response notFound = new;
        notFound.statusCode = 404;
        notFound.setTextPayload(
            string `Package '${org}/${name}' does not exist`,
            contentType = "text/plain"
        );
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
            notFound.setTextPayload(
                string `Package '${org}/${name}' does not exist`,
                contentType = "text/plain"
            );
            return notFound;
        }
        VersionsResponse versionsData = check responsePayload.cloneWithType();
        return versionsData.versions;
    }

    string[] versionList = check responsePayload.cloneWithType();
    return versionList;
}

// Fetches the bala bytes for a package version from Ballerina Central.
isolated function fetchBalaFromCentral(string org, string name, string version) returns byte[]|http:Response|error {
    http:Response versionMetadataResponse = check centralClient->get(
        string `/2.0/registry/packages/${org}/${name}/${version}`
    );

    if versionMetadataResponse.statusCode == 404 {
        log:printInfo("Package not found in central", org = org, name = name, version = version);
        http:Response notFound = new;
        notFound.statusCode = 404;
        notFound.setTextPayload(
            string `Package '${org}/${name}:${version}' does not exist`,
            contentType = "text/plain"
        );
        return notFound;
    }

    json responsePayload = check versionMetadataResponse.getJsonPayload();
    log:printInfo("Fetched version metadata from central", org = org, name = name, version = version, response = responsePayload);

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

    http:Client balaClient = check new (balaURL);
    http:Response balaResponse = check balaClient->get("");
    byte[] balaBytes = check balaResponse.getBinaryPayload();
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

// Builds the OCI manifest response for a given blob payload.
function buildManifestResponse(byte[] blobBytes) returns http:Response {
    byte[] hashBytes = crypto:hashSha256(blobBytes);
    string hexDigest = bytesToHex(hashBytes);
    string digest = "sha256:" + hexDigest;
    int blobSize = blobBytes.length();

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
      "size": ${blobSize},
      "digest": "${digest}"
    }
  ]
}`;

    digestToBlobContent[digest] = blobBytes;

    http:Response manifestResponse = new;
    manifestResponse.statusCode = 200;
    manifestResponse.setHeader("Content-Type", "application/vnd.oci.image.manifest.v1+json");
    manifestResponse.setHeader("Docker-Content-Digest", digest);
    manifestResponse.setTextPayload(ociManifest, contentType = "application/vnd.oci.image.manifest.v1+json");
    return manifestResponse;
}

// Builds the OCI manifest for the latest endpoint from the versions JSON payload.
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
        errResponse.setTextPayload("Failed to fetch from central: no versions available");
        return errResponse;
    }

    byte[] versionsBytes = fetchResult.toJsonString().toBytes();
    return buildManifestResponse(versionsBytes);
}

// Builds the OCI manifest for a specific package version from bala bytes.
function buildVersionManifestResponse(string org, string name, string version) returns http:Response|error {
    byte[]|http:Response|error fetchResult = fetchBalaFromCentral(org, name, version);
    if fetchResult is http:Response {
        return fetchResult;
    }
    if fetchResult is error {
        log:printError("Failed fetching bala from central", 'error = fetchResult, org = org, name = name, version = version);
        http:Response errResponse = new;
        errResponse.statusCode = 502;
        errResponse.setTextPayload("Failed to fetch from central: " + fetchResult.message());
        return errResponse;
    }

    return buildManifestResponse(fetchResult);
}

// Converts a byte array to a lowercase hex string
isolated function bytesToHex(byte[] bytes) returns string {
    string hexChars = "0123456789abcdef";
    string result = "";
    foreach byte b in bytes {
        int highNibble = (b & 0xF0) >> 4;
        int lowNibble = b & 0x0F;
        result = result + hexChars.substring(highNibble, highNibble + 1)
                        + hexChars.substring(lowNibble, lowNibble + 1);
    }
    return result;
}
