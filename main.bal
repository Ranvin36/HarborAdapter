import ballerina/http;
import ballerina/log;

final http:Client centralClient = check new ("https://api.central.ballerina.io",{
    timeout: 5
});

final string OCI_EMPTY_CONFIG_DIGEST = "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";

// Blob cache: digest -> bytes, populated on first fetch and reused on subsequent requests
isolated map<byte[]> blobCache = {};
// Blob source lookup: digest -> "org/name" or "org/name/version"
isolated map<string> blobSources = {};

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
        return buildLatestManifestResponse(org, name);
    }

    // GET /v2/{org}/{name}/manifests/{version}
    resource function get v2/[string org]/[string name]/manifests/[string version](http:Request req) returns http:Response|error {
        log:printInfo("Received GET manifest request", org = org, name = name, version = version);
        return buildVersionManifestResponse(org, name, version);
    }

    // HEAD /v2/{org}/{name}/manifests/{version}
    resource function head v2/[string org]/[string name]/manifests/[string version]() returns http:Response|error {
        log:printInfo("Received HEAD manifest request", org = org, name = name, version = version);
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
        http:Response headResponse = new;
        headResponse.statusCode = 200;
        headResponse.setHeader("Content-Type", "application/vnd.oci.image.manifest.v1+json");
        headResponse.setHeader("Docker-Content-Digest", digestResult);
        headResponse.setHeader("ETag", "\"" + digestResult + "\"");
        return headResponse;
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
        byte[]? cachedBlob;
        lock {
            byte[]? inner = blobCache[digest];
            cachedBlob = inner is byte[] ? inner.clone() : ();
        }
        if cachedBlob is byte[] {
            log:printInfo("Serving blob from cache", digest = digest);
            return buildBlobResponse(cachedBlob, digest, "application/octet-stream");
        }

        string? sourceKey;
        lock {
            sourceKey = blobSources[digest];
            log:printInfo("Source key for digest " ,sourceKey = sourceKey);
        }
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
            string versionsDigest = computeSha256Digest(versionsBytes);
            lock {
                blobCache[versionsDigest] = versionsBytes.clone();
            }
            lock {
                blobSources[versionsDigest] = sourceKey;
            }
            log:printInfo("Cached versions blob", digest = versionsDigest, size = versionsBytes.length());
            return buildBlobResponse(versionsBytes, versionsDigest, "application/octet-stream");

        } else if parts.length() == 3 {
            // "org/name/version" — serve bala bytes
            string decodedOrg = parts[0];
            string decodedName = parts[1];
            string decodedVersion = parts[2];
            log:printInfo("Serving bala blob", org = decodedOrg, name = decodedName, version = decodedVersion);

            byte[]|http:Response|error balaResult = fetchBalaFromCentral(decodedOrg, decodedName, decodedVersion);
            if balaResult is http:Response {
                return balaResult;
            }
            if balaResult is error {
                log:printError("Failed fetching bala", 'error = balaResult);
                http:Response errResponse = new;
                errResponse.statusCode = 502;
                errResponse.setTextPayload("Failed to fetch bala: " + balaResult.message());
                return errResponse;
            }

            string balaDigest = computeSha256Digest(balaResult);
            lock {
                blobCache[balaDigest] = balaResult.clone();
            }
            lock {
                blobSources[balaDigest] = sourceKey;
            }
            log:printInfo("Cached bala blob", digest = balaDigest, size = balaResult.length());
            return buildBlobResponse(balaResult, balaDigest, "application/octet-stream");

        } else {
            log:printError("Unexpected blob source format", sourceKey = sourceKey);
            http:Response notFound = new;
            notFound.statusCode = 404;
            notFound.setTextPayload("{\"errors\":[{\"code\":\"BLOB_UNKNOWN\"}]}", contentType = "application/json");
            return notFound;
        }
    }
}